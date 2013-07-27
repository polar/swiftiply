# This module rewrites pieces of the very good Mongrel web server in
# order to change it from a threaded application to an event based
# application running inside an EventMachine event loop.  It should
# be compatible with the existing Mongrel handlers for Rails,
# Camping, Nitro, etc....
 
begin
	load_attempted ||= false
	require 'eventmachine'
rescue LoadError
	unless load_attempted
		load_attempted = true
		require 'rubygems'
		retry
	end
end

require 'mongrel'

module Mongrel
	class MongrelProtocol < EventMachine::Connection
		
		Cblank = ''.freeze
		C400Header = "HTTP/1.0 400 Bad Request\r\nContent-Type: text/plain\r\nServer: Swiftiplied Mongrel 0.6.5\r\nConnection: close\r\n\r\n"
		
		def post_init
			@parser = HttpParser.new
			@params = HttpParams.new
			@nparsed = 0
			@request = nil
			@request_len = nil
			@linebuffer = ''
		end

		def receive_data data
			@linebuffer << data
			@nparsed = @parser.execute(@params, @linebuffer, @nparsed) unless @parser.finished?
			if @parser.finished?
				if @request_len.nil?
					@request_len = @params[::Mongrel::Const::CONTENT_LENGTH].to_i
					script_name, path_info, handlers = ::Mongrel::HttpServer::Instance.classifier.resolve(@params[::Mongrel::Const::REQUEST_PATH] || Cblank)
					if handlers
						@params[::Mongrel::Const::PATH_INFO] = path_info
						@params[::Mongrel::Const::SCRIPT_NAME] = script_name
						# The previous behavior of this line set REMOTE_ADDR equal to HTTP_X_FORWARDED_FOR
						# if it was defined.  This behavior seems inconsistent with the intention of
						# http://www.ietf.org/rfc/rfc3875 so it has been changed.  REMOTE_ADDR now always
						# contains the address of the immediate source of the connection.  Check
						# @params[::Mongrel::Const::HTTP_X_FORWARDED_FOR] if you need that information.
						@params[::Mongrel::Const::REMOTE_ADDR] = ::Socket.unpack_sockaddr_in(get_peername)[1] rescue nil
						@notifiers = handlers.select { |h| h.request_notify }
					end
					if @request_len > ::Mongrel::Const::MAX_BODY
						new_buffer = Tempfile.new(::Mongrel::Const::MONGREL_TMP_BASE)
						new_buffer.binmode
						new_buffer << @linebuffer[@nparsed..-1]
						@linebuffer = new_buffer
					else
						@linebuffer = StringIO.new(@linebuffer[@nparsed..-1])
						@linebuffer.pos = @linebuffer.length
					end
				end
				if @linebuffer.length >= @request_len
					@linebuffer.rewind
					::Mongrel::HttpServer::Instance.process_http_request(@params,@linebuffer,self)
					@linebuffer.delete if Tempfile === @linebuffer
				end
			elsif @linebuffer.length > ::Mongrel::Const::MAX_HEADER
				close_connection
				raise ::Mongrel::HttpParserError.new("HEADER is longer than allowed, aborting client early.")
			end
		rescue ::Mongrel::HttpParserError
			if $mongrel_debug_client
				STDERR.puts "#{Time.now}: BAD CLIENT (#{params[Const::HTTP_X_FORWARDED_FOR] || client.peeraddr.last}): #$!"
				STDERR.puts "#{Time.now}: REQUEST DATA: #{data.inspect}\n---\nPARAMS: #{params.inspect}\n---\n"
			end
			send_data C400Header
			close_connection_after_writing
		rescue Exception => e
			raise e
			send_data C400Header
			close_connection_after_writing
		end

		def write data
			send_data data
		end

		def closed?
			false
		end

	end

	class HttpServer
		def initialize(host, port, num_processors=950, x=0, y=nil) # Deal with Mongrel 1.0.1 or earlier, as well as later.
			@socket = nil
			@classifier = URIClassifier.new
			@host = host
			@port = port
			@workers = ThreadGroup.new
			if y
				@throttle = x
				@timeout = y || 60
			else
				@timeout = x
			end
			@num_processors = num_processors #num_processors is pointless for evented....
			@death_time = 60
			self.class.const_set(:Instance,self)
		end

		def run
			trap('INT') { raise StopServer }
			trap('TERM') { raise StopServer }
			#@acceptor = Thread.new do
			@acceptor = Thread.current
				# SHOULD NOT DO THIS AUTOMATICALLY.
				# There either needs to be a way to configure this, or to detect
				# when it is safe or when kqueue needs to run.
				EventMachine.epoll
				EventMachine.set_descriptor_table_size(4096)
				EventMachine.run do
					EM.set_timer_quantum(5)
					begin
						EventMachine.start_server(@host,@port.to_i,MongrelProtocol)
					rescue StopServer
						EventMachine.stop_event_loop
					end
				end
			#end
		end

		def process_http_request(params,linebuffer,client)
			if not params[Const::REQUEST_PATH]
				uri = URI.parse(params[Const::REQUEST_URI])
				params[Const::REQUEST_PATH] = uri.path
			end

 			raise "No REQUEST PATH" if not params[Const::REQUEST_PATH]

			script_name, path_info, handlers = @classifier.resolve(params[Const::REQUEST_PATH])

			if handlers
				notifiers = handlers.select { |h| h.request_notify }
				request = HttpRequest.new(params, linebuffer, notifiers)

				# TODO: Add Keep-Alive support

				# request is good so far, continue processing the response
				response = HttpResponse.new(client)

				# Process each handler in registered order until we run out or one finalizes the response.
				dispatch_to_handlers(handlers,request,response)

				# And finally, if nobody closed the response off, we finalize it.
				unless response.done
					response.finished
				else
					response.close_connection_after_writing
				end
			else
				# Didn't find it, return a stock 404 response.
				client.send_data(Const::ERROR_404_RESPONSE)
				client.close_connection_after_writing
			end
		end
		
		def dispatch_to_handlers(handlers,request,response)
			handlers.each do |handler|
				handler.process(request, response)
				break if response.done
			end
		end
	end

	class HttpRequest
		def initialize(params, linebuffer, dispatchers)
			@params = params
			@dispatchers = dispatchers
			@body = linebuffer
		end
	end

	class HttpResponse

    CContentLength = 'Content-Length'.freeze
    C1_1 = '1.1'.freeze

    def send_status(content_length=@body.length)
      unless @status_sent
        if content_length
          if @status != 304
            @header[CContentLength] = content_length
          end
          @packetize = false
        else
          @header['X-Swiftiply-Close'] = "true"
          @packetize = true
        end
        if @keepalive
          write("HTTP/1.1 #{@status} #{@reason || HTTP_STATUS_CODES[@status]}\r\nConnection: Keep-Alive\r\n")
        else
          write("HTTP/1.1 #{@status} #{@reason || HTTP_STATUS_CODES[@status]}\r\nConnection: Close\r\n")
        end
        @status_sent = true
      end
    end

    def send_file(path, small_file = false)
      File.open(path, "rb") do |f|
        while chunk = f.read(Const::CHUNK_SIZE) and chunk.length > 0
          begin
            write(chunk)
          rescue Object => exc
            break
          end
        end
        write("--------") if @packetize
      end
      @body_sent = true
    end

		def write(data)
      if @status_sent && @header_sent && @packetize
        @socket.send_data "%08d" % data.length
      end
			@socket.send_data data
		end

		def close_connection_after_writing
			@socket.close_connection_after_writing
		end

		def socket_error(details)
			@socket.close_connection
			done = true
			raise details
		end

		def finished
			send_status
			send_header
			send_body
      @socket.send_data "--------" if @packetize
			@socket.close_connection_after_writing
		end
	end
	
	class Configurator
		# This version fixes a bug in the regular Mongrel version by adding
		# initialization of groups.
		def change_privilege(user, group)
			if user and group
				log "Initializing groups for {#user}:{#group}."
				Process.initgroups(user,Etc.getgrnam(group).gid)
			end
			
			if group
				log "Changing group to #{group}."
				Process::GID.change_privilege(Etc.getgrnam(group).gid)
			end
			
			if user
				log "Changing user to #{user}."
				Process::UID.change_privilege(Etc.getpwnam(user).uid)
			end
		rescue Errno::EPERM
			log "FAILED to change user:group #{user}:#{group}: #$!"
			exit 1
		end
	end
end
