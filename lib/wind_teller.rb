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

    actor_epoll.add(@serialport, SleepyPenguin::Epoll::IN)

    every(1.second) do
      @amqp.tell AM::AMQP::MsgPublish.new(
        destination: mycfg.exchange,
        payload: {
          station_id: 'WS',
          time: Time.now,
          dir: 330,
          spd: 35.0,
        },
        options: {
          type: 'WIND',
          persistent: false,
          mandatory: false,
          expiration: 5000,
        }
      )
    end
  end

  def actor_receive(events, io)
    case io
    when @serialport
      data = @serialport.read_nonblock(65536)

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

    if line =~ /\$([A-Z]+),(.*)\*([0-9A-F][0-9A-F])$/
      sum = line[1..-4].chars.inject(0) { |a,x| a ^ x.ord }
      chk = $3.to_i(16)

      if sum == chk
        handle_nmea($1, $2)
      else
        log.error "NMEA CHK INCORRECT"
      end
    end
  end

  def handle_nmea(msg, values)
    case msg
    when '$IIMWV' ; handle_iimwv(values)
    when '$WIXDR' ; handle_wixdr(values)
    end
  end

  def handle_iimwv(line)
    (wind_dir, relative, wind_speed, wind_speed_unit, status) = nmea_parse(line)

    wind_dir = wind_dir.to_f

    case wind_speed_unit
    when 'N': wind_speed = (wind_speed.to_f * 1854) / 3600
    when 'K': wind_speed = (wind_speed.to_f * 1000) / 3600
    when 'M': wind_speed = wind_speed.to_f
    when 'S': wind_speed = (wind_speed.to_f * 1609) / 3600
    end

    @amqp.tell AM::AMQP::MsgPublish.new(
      destination: mycfg.exchange,
      payload: {
        msg_type: :station_update,
        msg: {
          station_id: 'WS',
          time: @time,
          data: {
            wind_ok: status == 'A',
            wind_dir: wind_dir,
            wind_speed: wind_speed,
          }
        },
      },
      options: {
        type: 'WX_UPDATE',
        persistent: false,
        mandatory: false,
        expiration: 60000,
      }
    )
  end

  def handle_wixdr(line)
    data = nmea_parse(line, no_checksum: true)

    (data.length / 2).each do |i|
      case data[i * 2 + 1]
      when 'B'
        pressure = data[i * 2]
      when 'C'
        temperature = data[i * 2]
    end

    @amqp.tell AM::AMQP::MsgPublish.new(
      destination: mycfg.exchange,
      payload: {
        msg_type: :station_update,
        msg: {
          station_id: 'WS',
          time: @time,
          data: {
            pressure: pressure.to_f,
            temperature: temperature.to_f,
          }
        },
      },
      options: {
        type: 'WX_UPDATE',
        persistent: false,
        mandatory: false,
        expiration: 60000,
      }
    )


  end

  def nmea_parse(line, **args)
    line.split(',')
  end
end

end
