module Swiftcore
  module Swiftiply

		# The ClusterProtocol is the subclass of EventMachine::Connection used
		# to communicate between Swiftiply and the web browser clients.

		class ClusterProtocol < EventMachine::Connection

#			include Swiftcore::MicroParser

			attr_accessor :create_time, :last_action_time, :uri, :associate, :name, :redeployable, :data_pos, :data_len, :peer_ip, :connection_header, :keepalive

			Crn = "\r\n".freeze
			Crnrn = "\r\n\r\n".freeze
			C_blank = ''.freeze
			C_percent = '%'.freeze
			Cunknown_host = 'unknown host'.freeze
			C503Header = "HTTP/1.1 503 Server Unavailable\r\nContent-Type: text/plain\r\nConnection: close\r\n\r\n"
			C404Header = "HTTP/1.1 404 Not Found\r\nContent-Type: text/plain\r\nConnection: close\r\n\r\n"
			C400Header = "HTTP/1.1 400 Bad Request\r\nContent-Type: text/plain\r\nConnection: close\r\n\r\n"

      def self.init_class_variables
        @count_503 = 0
        @count_404 = 0
        @count_400 = 0
      end

      def self.increment_503_count
        @count_503 += 1
      end
      
      def self.increment_404_count
        @count_404 += 1
      end
      
      def self.increment_400_count
        @count_400 += 1
      end

			# Initialize the @data array, which is the temporary storage for blocks
			# of data received from the web browser client, then invoke the superclass
			# initialization.

			def initialize *args
				@data = Deque.new
				#@data = []
				@data_pos = 0
				@connection_header = C_empty
				@hmp = @name = @uri = @http_version = @request_method = @none_match = @done_parsing = nil
				@keepalive = true
				@klass = self.class
				super
			end

			def reset_state
				@data.clear
				@data_pos = 0
				@connection_header = C_empty
				@hmp = @name = @uri = @http_version = @request_method = @none_match = @done_parsing = nil
				@keepalive = true
			end
			
			# States:
			# uri
			# name
			# \r\n\r\n
			#   If-None-Match
			# Done Parsing
			def receive_data data
				if @done_parsing
					@data.unshift data
					push
				else
					unless @uri
						# It's amazing how, when writing the code, the brain can be in a zone
						# where line noise like this regexp makes perfect sense, and is clear
						# as day; one looks at it and it reads like a sentence.  Then, one
						# comes back to it later, and looks at it when the brain is in a
						# different zone, and 'lo!  It looks like line noise again.
						#
						# data =~ /^(\w+) +(?:\w+:\/\/([^\/]+))?([^ \?]+)\S* +HTTP\/(\d\.\d)/
						#
						# In case it looks like line noise to you, dear reader, too:						
						#
						# 1) Match and save the first set of word characters.
						#
						#    Followed by one or more spaces.
						#
						#    Match but do not save the word characters followed by ://
						#
						#    2) Match and save one or more characters that are not a slash
						#
						#    And allow this whole thing to match 1 or 0 times.
						#
						# 3) Match and save one or more characters that are not a question
						#    mark or a space.
						#
						#    Match zero or more non-whitespace characters, followed by one
						#    or more spaces, followed by "HTTP/".
						#
						# 4) Match and save a digit dot digit.
						#
						# Thus, this pattern will match both the standard:
						#   GET /bar HTTP/1.1
						# style request, as well as the valid (for a proxy) but less common:
						#   GET http://foo/bar HTTP/1.0
						#
						# If the match fails, then this is a bad request, and an appropriate
						# response will be returned.
						#
						# http://www.w3.org/Protocols/rfc2616/rfc2616-sec3.html#sec5.1.2
						#
						if data =~ /^(\w+) +(?:\w+:\/\/([^ \/]+))?([^ \?\#]*)\S* +HTTP\/(\d\.\d)/
							@request_method = $1
							@uri = $3
							@http_version = $4
							if $2
								@name = $2.intern
								@uri = C_slash if @uri.empty?
								# Rewrite the request to get rid of the http://foo portion.
								
								data.sub!(/^\w+ +\w+:\/\/[^ \/]+([^ \?]*)/,"#{@request_method} #{@uri}")
							end
							@uri = @uri.tr('+', ' ').gsub(/((?:%[0-9a-fA-F]{2})+)/n) {[$1.delete(C_percent)].pack('H*')} if @uri.include?(C_percent)
						else
							send_400_response
							return
						end
					end
					unless @name
						if data =~ /^Host: *([^\r\0:]+)/
							@name = $1.intern
						end
					end
					if @hmp
						# Hopefully this doesn't happen often.
						d = @data.to_s
					else
						d = data
						@hmp = true
					end
					if d.include?(Crnrn)
						@name = ProxyBag.default_name unless ProxyBag.incoming_mapping(@name)
						@done_parsing = true
						if data =~ /If-None-Match: *([^\r]+)/
							@none_match = $1
						end

						# Keep-Alive works differently on HTTP 1.0 versus HTTP 1.1
						# HTTP 1.0 was not written to support Keep-Alive initially; it was
						# bolted on.  Thus, for an HTTP 1.0 client to indicate that it
						# wants to initiate a Keep-Alive session, it must send a header:
						#
						# Connection: Keep-Alive
						#
						# Then, when the server sends the response, it must likewise add:
						#
						# Connection: Keep-Alive
						#
						# to the response.
						#
						# For HTTP 1.1, Keep-Alive is assumed.  If a client does not want
						# Keep-Alive, then it must send the following header:
						#
						# Connection: close
						#
						# Likewise, if the server does not want to keep the connection
						# alive, it must send the same header:
						#
						# Connection: close
						#
						# to the client.
						
						if @name
							unless ProxyBag.keepalive(@name) == false
								if @http_version == C1_0
									if data =~ /Connection: [Kk]eep-[Aa]live/i
										# Nonstandard HTTP 1.0 situation; apply keepalive header.
										@connection_header = CConnection_KeepAlive
									else
										# Standard HTTP 1.0 situation; connection will be closed.
										@keepalive = false
										@connection_header = CConnection_close
									end
								else # The connection is an HTTP 1.1 connection.
									if data =~ /Connection: [Cc]lose/
										# Nonstandard HTTP 1.1 situation; connection will be closed.
										@keepalive = false
									end
								end
							end
							
							ProxyBag.add_frontend_client(self,@data,data)
						else
							send_404_response
						end						
					else
						@data.unshift data
					end
				end
			end
			
			# Hardcoded 400 response that is sent if the request is malformed.

			def send_400_response
				ip = Socket::unpack_sockaddr_in(get_peername).last rescue Cunknown_host
				error = "The request received on #{ProxyBag.now.asctime} from #{ip} was malformed and could not be serviced."
				send_data "#{C400Header}Bad Request\n\n#{error}"
				ProxyBag.logger.log(Cinfo,"Bad Request -- #{error}")
				close_connection_after_writing
				increment_400_count
			end

			# Hardcoded 404 response.  This is sent if a request can't be matched to
			# any defined incoming section.

			def send_404_response
				ip = Socket::unpack_sockaddr_in(get_peername).last rescue Cunknown_host
				error = "The request (#{@uri} --> #{@name}), received on #{ProxyBag.now.asctime} from #{ip} did not match any resource know to this server."
				send_data "#{C404Header}Resource not found.\n\n#{error}"
				ProxyBag.logger.log(Cinfo,"Resource not found -- #{error}")
				close_connection_after_writing
				increment_404_count
			end
	
			# Hardcoded 503 response that is sent if a connection is timed out while
			# waiting for a backend to handle it.

			def send_503_response
				ip = Socket::unpack_sockaddr_in(get_peername).last rescue Cunknown_host
				error = "The request (#{@uri} --> #{@name}), received on #{create_time.asctime} from #{ip} timed out before being deployed to a server for processing."
				send_data "#{C503Header}Server Unavailable\n\n#{error}"
				ProxyBag.logger.log(Cinfo,"Server Unavailable -- #{error}")
				close_connection_after_writing
				increment_503_count
			end
	
			# Push data from the web browser client to the backend server process.

			def push
				if @associate
					unless @redeployable
						# normal data push
						data = nil
						@associate.send_data data while data = @data.pop
					else
						# redeployable data push; just send the stuff that has
						# not already been sent.
						(@data.length - 1 - @data_pos).downto(0) do |p|
							d = @data[p]
							@associate.send_data d
							@data_len += d.length
						end
						@data_pos = @data.length

						# If the request size crosses the size limit, then
						# disallow redeployment of this request.
						if @data_len > @redeployable
							@redeployable = false
							@data.clear
						end
					end
				end
			end

			# The connection with the web browser client has been closed, so the
			# object must be removed from the ProxyBag's queue if it is has not
			# been associated with a backend.  If it has already been associated
			# with a backend, then it will not be in the queue and need not be
			# removed.

			def unbind
				ProxyBag.remove_client(self) unless @associate
			end

			def request_method; @request_method; end
			def http_version; @http_version; end
			def none_match; @none_match; end

			def setup_for_redeployment
				@data_pos = 0
			end

			def increment_503_count
				@klass.increment_503_count
			end
			
			def increment_404_count
				@klass.increment_404_count
			end
			
			def increment_400_count
				@klass.increment_400_count
			end
			
		end
  end
end
