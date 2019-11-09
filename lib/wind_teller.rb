#!/usr/bin/env ruby
#
# Copyright (C) 2014-2015, Daniele Orlandi
#
# Author:: Daniele Orlandi <daniele@orlandi.com>
#
# License:: You can redistribute it and/or modify it under the terms of the LICENSE file.
#

require 'active_support/core_ext'

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

  class WindSample
    attr_accessor :ts
    attr_accessor :speed
    attr_accessor :dir
    attr_accessor :vec
    attr_accessor :gst

    def initialize(**pars)
      pars.each { |k,v| send("#{k}=", v) }
    end
  end

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

    actor_epoll.add(@serialport, AM::Epoll::IN)

    @wind_sps = 2

    @history_size = 600 * @wind_sps # 600 seconds
    @history = []
  end

  def actor_receive(events, io)
    case io
    when @serialport
      data = @serialport.read_nonblock(65536)

      log.debug "Serial Raw" if mycfg.debug_serial_raw

      if !data || data.empty?
        actor_epoll.del(@socket)
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
    when 'N'; wind_speed = (wind_speed.to_f * 1854) / 3600.0
    when 'K'; wind_speed = (wind_speed.to_f * 1000) / 3600.0
    when 'M'; wind_speed = wind_speed.to_f
    when 'S'; wind_speed = (wind_speed.to_f * 1609) / 3600.0
    end

    # Record instantaneous values

    @wind_speed = wind_speed
    @wind_dir = wind_dir

    # Push history data

    wind_dir_rad = (wind_dir / 180) * Math::PI

    gst = @history.size >= (3 * @wind_sps) ?
            @history.last(3 * @wind_sps).map(&:speed).reduce(:+) / (3.0 * @wind_sps) :
            wind_speed

    @history.push(WindSample.new(
      ts: Time.now,
      speed: wind_speed,
      dir: wind_dir,
      vec: Complex.polar(wind_speed, wind_dir_rad),
      gst: gst,
    ))

    if @history.size > @history_size
      @history.slice!(-@history_size..-1)
    end

    # Calculate average and gust

    hist_size = @history.size

    last_2m = @history.last(120 * @wind_sps)
    @wind_2m_avg = last_2m.map(&:speed).reduce(:+) / hist_size
    @wind_2m_vec = last_2m.map(&:vec).reduce(:+) / hist_size
    ( @wind_2m_gst, gst_idx ) = last_2m.map(&:gst).each_with_index.max
    @wind_2m_gst_dir = last_2m[gst_idx].dir
    @wind_2m_gst_ts = last_2m[gst_idx].ts

    last_10m = @history
    @wind_10m_avg = last_10m.map(&:speed).reduce(:+) / hist_size
    @wind_10m_vec = last_10m.map(&:vec).reduce(:+) / hist_size
    ( @wind_10m_gst, gst_idx ) = last_10m.map(&:gst).each_with_index.max
    @wind_10m_gst_dir = last_10m[gst_idx].dir
    @wind_10m_gst_ts = last_10m[gst_idx].ts

    ####

    if mycfg.debug_data
      log.debug "Wind #{'%.1f' % wind_speed} m/s from #{wind_dir.to_i}° " +
                " avg_2m=#{'%.1f' % @wind_2m_avg}" +
                " vec_2m=#{'%.1f' % @wind_2m_vec.magnitude}@#{'%.0f' % (((@wind_2m_vec.phase / Math::PI) * 180) % 360)}" +
                " gst_2m=#{'%.1f' % @wind_2m_gst} from #{'%.1f' % @wind_2m_gst_dir} at #{@wind_2m_gst_ts}" +
                " avg_10m=#{'%.1f' % @wind_10m_avg}" +
                " vec_10m=#{'%.1f' % @wind_10m_vec.magnitude}@#{'%.0f' % (((@wind_10m_vec.phase / Math::PI) * 180) % 360)}" +
                " gst_10m=#{'%.1f' % @wind_10m_gst} from #{'%.1f' % @wind_10m_gst_dir} at #{@wind_10m_gst_ts}"
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
          wind_2m_gst_dir: @wind_2m_gst_dir,
          wind_2m_gst_ts: @wind_2m_gst_ts,
          wind_10m_avg: @wind_10m_avg,
          wind_10m_gst: @wind_10m_gst,
          wind_10m_vec_mag: @wind_10m_vec.magnitude,
          wind_10m_vec_dir: ((@wind_10m_vec.phase / Math::PI) * 180) % 360,
          wind_10m_gst_dir: @wind_10m_gst_dir,
          wind_10m_gst_ts: @wind_10m_gst_ts,
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
