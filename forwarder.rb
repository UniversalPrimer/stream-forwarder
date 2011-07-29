#!/usr/bin/env ruby

require 'socket'
require 'rubygems'
require 'eventmachine'
require 'yaml'


module RTMPForwarder

  def initialize(stream_receiver)
    @state = :connecting
    @stream_receiver = stream_receiver
  end

  def post_init
    @state = :connected
    # inform the stream receiver that a connection has been established
    @stream_receiver.rtmp_forwarder_connected = true
  end

  def finish
    close_connection_after_writing
  end

  def unbind
    if @state == :connecting
      puts "Could not connect to RTMP server or connection"
    elsif @state == :connected
      puts "Connection to RTMP server was lost"
    end
    @stream_receiver.abort
  end

end

module StorageForwarder

  def initialize(stream_receiver)
    @stream_receiver = stream_receiver
  end

  def post_init
    # inform the stream receiver that a connection has been established
    @stream_receiver.storage_forwarder_connected = true

    @received = ''
    @video_id = nil
  end

  def receive_data(data)
    return false if @video_id != nil
    @received += data
    if @received.length >= 36
      @video_id = @received[0..35]
      puts "got video id #{@video_id}"
    end
  end

  def finish
    close_connection_after_writing
  end

  def unbind
    if @state == :connecting
      puts "Could not connect to storage server or connection"
    elsif @state == :connected
      puts "Connection to storage server was lost"
    end
    @stream_receiver.abort
  end
end

module StreamReceiver

  attr_accessor :storage_forwarder_connected, :rtmp_forwarder_connected

  def post_init
#    puts 'post init'
    @bytes_received = 0
    @storage_buffer = ''
    @rtmp_buffer = ''
    port, ip = Socket.unpack_sockaddr_in(get_peername)
    puts "connection from #{ip}:#{port}"

    @storage_forwarder = EventMachine::connect $config['storage_host'], $config['storage_port'], StorageForwarder, self
    @storage_forwarder.set_pending_connect_timeout(7) # set timeout to 7 seconds

    @rtmp_forwarder = EventMachine::connect $config['rtmp_host'], $config['rtmp_port'], RTMPForwarder, self
    @rtmp_forwarder.set_pending_connect_timeout(7) # set timeout to 7 seconds
    @timer = nil
  end

  def receive_data(data)
    @bytes_received += data.length

    if storage_forwarder_connected
      if @storage_buffer.length > 0
        @storage_forwarder.send_data(@storage_buffer)
        @storage_buffer = ''
      end
      @storage_forwarder.send_data(data)
    else
      @storage_buffer += data
    end

    if rtmp_forwarder_connected
      if @rtmp_buffer.length > 0
        @rtmp_forwarder.send_data(@rtmp_buffer)
        @rtmp_buffer = ''
      end
      @rtmp_forwarder.send_data(data)
    else
      @rtmp_buffer += data
    end

    unless @timer
      @timer = EM.add_periodic_timer(3) do
        puts "Data received: #{@bytes_received}"
      end
    end
  end

  def unbind
    finish
  end

  def finish
    @timer.cancel if @timer
    @storage_forwarder.finish
    close_connection_after_writing
  end

  def abort
    puts "Incoming connection dropped."
    finish
  end
end


$config = YAML.load_file('config.yaml')

EventMachine::run do

  EventMachine::start_server $config['listen_host'], $config['listen_port'], StreamReceiver
  puts "Stream Server started on #{$config['listen_host']}:#{$config['listen_port']}"

end
