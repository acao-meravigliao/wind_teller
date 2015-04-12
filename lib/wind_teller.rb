#!/usr/bin/env ruby
#
# Copyright (C) 2014-2015, Daniele Orlandi
#
# Author:: Daniele Orlandi <daniele@orlandi.com>
#
# License:: You can redistribute it and/or modify it under the terms of the LICENSE file.
#

require 'ygg/agent/base'

require 'ygg/app/line_buffer'

require 'wind_teller/version'
require 'wind_teller/task'

require 'serialport'


module WindTeller

class App < Ygg::Agent::Base
  self.app_name = 'wind_teller'
  self.app_version = VERSION
  self.task_class = Task

  def prepare_default_config
    app_config_files << File.join(File.dirname(__FILE__), '..', 'config', 'wind_teller.conf')
    app_config_files << '/etc/yggdra/wind_teller.conf'
  end

  def prepare_options(o)
    o.on("--debug-data", "Logs decoded data") { |v| @config['wind_teller.debug_data'] = true }
    o.on("--debug-nmea", "Logs NMEA messages") { |v| @config['wind_teller.debug_nmea'] = true }
    o.on("--debug-serial", "Logs serial lines") { |v| @config['wind_teller.debug_serial'] = true }
    o.on("--debug-serial-raw", "Logs serial bytes") { |v| @config['wind_teller.debug_serial_raw'] = true }

    super
  end


  def agent_boot
    @amqp.ask(AM::AMQP::MsgDeclareExchange.new(
      name: mycfg.exchange,
      type: :topic,
      options: {
        durable: true,
        auto_delete: false,
      }
    )).value

    @line_buffer = Ygg::App::LineBuffer.new(line_received_cb: method(:receive_line))

    @serialport = SerialPort.new(mycfg.serial.device,
      'baud' => mycfg.serial.speed,
      'data_bits' => 8,
      'stop_bits' => 1,
      'parity' => SerialPort::NONE)

    @actor_epoll.add(@serialport, SleepyPenguin::Epoll::IN)

    @history_speed = []
    @history_dir = []
    @history_gst = []
  end

  def receive(events, io)
    case io
    when @serialport
      data = @serialport.read_nonblock(65536)

      log.debug "Serial Raw" if mycfg.debug_serial_raw

      if !data || data.empty?
        @actor_epoll.del(@socket)
        actor_exit
        return
      end

      @line_buffer.push(data)
    else
      super
    end
  end

  def receive_line(line)
    line.chomp!

    log.debug "Serial Line" if mycfg.debug_serial

    if line =~ /^\$([A-Z]+),(.*)\*([0-9A-F][0-9A-F])$/
      sum = line[1..-4].chars.inject(0) { |a,x| a ^ x.ord }
      chk = $3.to_i(16)

      if sum == chk
        handle_nmea($1, $2)
      else
        log.error "NMEA CHK INCORRECT"
      end
    elsif line =~ /^\$([A-Z]+),(.*)$/
      handle_nmea($1, $2) # Workaround for messages withoud checksum
    end
  end

  def handle_nmea(msg, values)
    log.debug "NMEA #{msg} #{values}" if mycfg.debug_nmea

    case msg
    when 'IIMWV' ; handle_iimwv(values)
    when 'WIMDA' ; handle_wimda(values)
    end
  end

  def handle_iimwv(line)
    (wind_dir, relative, wind_speed, wind_speed_unit, status) = nmea_parse(line)

    wind_dir = wind_dir.to_f

    case wind_speed_unit
    when 'N'; wind_speed = (wind_speed.to_f * 1854) / 3600
    when 'K'; wind_speed = (wind_speed.to_f * 1000) / 3600
    when 'M'; wind_speed = wind_speed.to_f
    when 'S'; wind_speed = (wind_speed.to_f * 1609) / 3600
    end

    # Record instantaneous values

    @wind_speed = wind_speed
    @wind_dir = wind_dir

    # Push history data

    @history_speed.push(wind_speed)
    @history_dir.push(wind_dir)
    @history_gst.push(@history_speed.last(6).reduce(:+) / 6.0)

    if @history_speed.length > 240
      @history_speed.slice!(0...@history_speed.length - 240)
      @history_dir.slice!(0...@history_dir.length - 240)
      @history_gst.slice!(0...@history_gst.length - 240)
    end

    # Calculate average and gust

    @wind_2m_avg = @history_speed.reduce(:+) / @history_speed.size
    @wind_2m_gst = @history_gst.max

    ####

    log.debug "Wind #{'%.1f' % wind_speed} m/s from #{wind_dir.to_i}° Avg2m=#{@wind_2m_avg} Gst2m=#{@wind_2m_gst}" if mycfg.debug_data

    @amqp.tell AM::AMQP::MsgPublish.new(
      destination: mycfg.exchange,
      payload: {
        station_id: 'WS',
        time: Time.now,
        data: {
          wind_ok: status == 'A',
          wind_dir: @wind_dir,
          wind_speed: @wind_speed,
          wind_2m_avg: @wind_2m_avg,
          wind_2m_gst: @wind_2m_gst,
        },
      },
      routing_key: 'WS',
      options: {
        type: 'WX_UPDATE',
        persistent: false,
        mandatory: false,
      },
    )
  end

  def handle_wimda(line)
    data = nmea_parse(line, no_checksum: true)

    pressure = nil
    temperature = nil

    (data.length / 2).times do |i|
      case data[i * 2 + 1]
      when 'B'
        pressure = data[i * 2].to_f
      when 'C'
        temperature = data[i * 2].to_f
      end
    end

    log.debug "Pressure #{pressure * 1000} mb, Temperature #{temperature}" if mycfg.debug_data

    @amqp.tell AM::AMQP::MsgPublish.new(
      destination: mycfg.exchange,
      payload: {
        station_id: 'WS',
        time: @time,
        data: {
          pressure: pressure,
          temperature: temperature,
        }
      },
      routing_key: 'WS',
      options: {
        type: 'WX_UPDATE',
        persistent: false,
        mandatory: false,
      }
    )


  end

  def nmea_parse(line, **args)
    line.split(',')
  end
end

end
