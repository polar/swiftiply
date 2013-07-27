# This module rewrites pieces of the very good Mongrel web server in
# order to change it from a threaded application to an event based
# application running inside an EventMachine event loop.  It should
# be compatible with the existing Mongrel handlers for Rails,
# Camping, Nitro, etc....
 
begin
	load_attempted ||= false
  require "swiftcore/swiftiplied_mongrel"
  require "swiftcore/evented_mongrel"
rescue LoadError
	unless load_attempted
		load_attempted = true
		require 'rubygems'
		retry
	end
end


module Mongrel

	class HttpServer

    def initialize(host, port, num_processors=950, x=0, y=nil,key='') # Deal with Mongrel 1.0.1 or earlier, as well as later.
      @socket = nil
      @classifier = URIClassifier.new
      @host = host
      @port = port
      @key = key
      @workers = ThreadGroup.new
      if y
        @throttle = x
        @timeout = y || 60
      else
        @timeout = x
      end
      @num_processors = num_processors
      @death_time = 60
      self.class.const_set(:Instance,self)
    end

    def run
      puts "We are a Swiftiplied Evented Mongrel #{@host} #{@post}"
      trap('INT') { EventMachine.stop_event_loop }
      trap('TERM') { EventMachine.stop_event_loop }
      #@acceptor = Thread.new do
      @acceptor = Thread.current
      EventMachine.run do
        EM.set_timer_quantum(5)
        begin
          SwiftiplyMongrelProtocol.connect(@host,@port.to_i,@key)
        rescue StopServer
          EventMachine.stop_event_loop
        end
      end
      #end
    end
  end

end
