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

    @history_size = 1200 # 600 samples * 2 samples/second = 1200 seconds

    @history_speed = []
    @history_dir = []
    @history_vec = []
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

    wind_dir_rad = (wind_dir / 180) * Math::PI

    @history_speed.push(wind_speed)
    @history_dir.push(wind_dir)
    @history_vec.push(Complex.polar(wind_speed, wind_dir_rad))
    @history_gst.push(@history_speed.last(6).reduce(:+) / 6.0)

    hist_size = @history_speed.length

    if hist_size > @history_size
      @history_speed.slice!(-@history_size..-1)
      @history_dir.slice!(-@history_size..-1)
      @history_vec.slice!(-@history_size..-1)
      @history_gst.slice!(-@history_size..-1)
    end

    # Calculate average and gust

    @wind_2m_avg = @history_speed.last(240).reduce(:+) / hist_size
    @wind_2m_vec = @history_vec.last(240).reduce(:+) / hist_size
    @wind_2m_gst = @history_gst.last(240).max

    @wind_10m_avg = @history_speed.reduce(:+) / hist_size
    @wind_10m_vec = @history_vec.reduce(:+) / hist_size
    @wind_10m_gst = @history_gst.max

    ####

    if mycfg.debug_data
      log.debug "Wind #{'%.1f' % wind_speed} m/s from #{wind_dir.to_i}° " +
                " avg_2m=#{'%.1f' % @wind_2m_avg} gst_2m=#{'%.1f' % @wind_2m_gst}" +
                " vec_2m=#{'%.1f' % @wind_2m_vec.magnitude}@#{'%.0f' % (((@wind_2m_vec.phase / Math::PI) * 180) % 360)}" +
                " avg_10m=#{'%.1f' % @wind_10m_avg} gst_10m=#{'%.1f' % @wind_10m_gst}" +
                " vec_10m=#{'%.1f' % @wind_10m_vec.magnitude}@#{'%.0f' % (((@wind_10m_vec.phase / Math::PI) * 180) % 360)}"
    end

    @amqp.tell AM::AMQP::MsgPublish.new(
      destination: mycfg.exchange,
      payload: {
        station_id: 'WS',
        data: {
          wind_ok: status == 'A',
          wind_dir: @wind_dir,
          wind_speed: @wind_speed,
          wind_2m_avg: @wind_2m_avg,
          wind_2m_vec_mag: @wind_2m_vec.magnitude,
          wind_2m_vec_dir: ((@wind_2m_vec.phase / Math::PI) * 180) % 360,
          wind_2m_gst: @wind_2m_gst,
          wind_10m_avg: @wind_10m_avg,
          wind_10m_gst: @wind_10m_gst,
          wind_10m_vec_mag: @wind_10m_vec.magnitude,
          wind_10m_vec_dir: ((@wind_10m_vec.phase / Math::PI) * 180) % 360,
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

    (data.length / 2).times do |i|
      case data[i * 2 + 1]
      when 'B'
        @qfe = (data[i * 2].to_f * 100000 + mycfg.qfe_cal_offset) * mycfg.qfe_cal_scale
      when 'C'
        @temperature = data[i * 2].to_f
      end
    end

    hisa = 44330.77 - (11880.32 * ((@qfe / 100) ** 0.190263))
    @qnh = 101325 * (( 1 - (0.0065 * ((hisa - mycfg.qfe_height)/288.15))) ** 5.25588)

    if mycfg.debug_data
      log.debug "QFE=#{'%0.1f' % (@qfe / 100)} hPa " +
                "QNH=#{'%0.1f' % (@qnh / 100)} hPa, " +
                "Temperature #{'%0.1f' % @temperature}"
    end

    @amqp.tell AM::AMQP::MsgPublish.new(
      destination: mycfg.exchange,
      payload: {
        station_id: 'WS',
        time: @time,
        data: {
          qfe: @qfe,
          qfe_h: mycfg.qfe_height,
          isa_h: hisa,
          qnh: @qnh,
          temperature: @temperature,
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
