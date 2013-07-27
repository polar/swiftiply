module Swiftcore
  module Swiftiply

    # The BackendProtocol is the EventMachine::Connection subclass that
    # handles the communications between Swiftiply and the backend process
    # it is proxying to.

    class BackendProtocol < EventMachine::Connection
      attr_accessor :associate, :id

      C0rnrn = "0\r\n\r\n".freeze
      Crnrn = "\r\n\r\n".freeze

      def initialize *args
        @name             = self.class.bname
        @permit_xsendfile = self.class.xsendfile
        @enable_sendfile_404 = self.class.enable_sendfile_404
        super
      end

      def name
        @name
      end

      # Call setup() and add the backend to the ProxyBag queue.

      def post_init
        setup
        @initialized = nil
        ProxyBag.add_server self
      end

      # Setup the initial variables for receiving headers and content.

      def setup
        @headers      = ''
        @headers_completed = @dont_send_data = false
        @content_length = nil
        @content_sent = 0
        @filter       = self.class.filter
      end

      # Receive data from the backend process.  Headers are parsed from
      # the rest of the content.  If a Content-Length header is present,
      # that is used to determine how much data to expect.  Otherwise,
      # if 'Transfer-encoding: chunked' is present, assume chunked
      # encoding.  Otherwise be paranoid; something isn't the way we like
      # it to be.

      # This call is also recursive when there is subsequent data after
      # content length is sent.

      def receive_data data
        unless @initialized
          begin
            # preamble = data.slice!(0..24)
            preamble = data[0..24]
            data   = data[25..-1] || C_empty
            keylen = preamble[23..24].to_i(16)
            keylen = 0 if keylen < 0
            key = keylen > 0 ? data.slice!(0..(keylen - 1)) : C_empty
            #if preamble[0..10] == Cswiftclient and key == ProxyBag.get_key(@name)
            if preamble.index(Cswiftclient) == 0 and key == ProxyBag.get_key(@name)
              @id = preamble[11..22]
              ProxyBag.add_id(self, @id)
              @initialized = true
              puts "New Backend: #{id} - #{self.__id__} #{comm_inactivity_timeout}"
            else
              puts "New Backend: Unauthenticated Connection"
              # The worker that connected did not present the proper authentication,
              # so something is fishy; time to cut bait.
              close_connection
              return
            end
          rescue Exception => boom
            puts "New Backend: Bad Data"
            # The worker that connected did not present the proper authentication,
            # so something is fishy; time to cut bait.
            close_connection
            return
          end
        end

        unless @headers_completed
          # TODO: This is a little dicey. Only works if we know we got the request from the beginning.
          if data.include?(Crnrn)
            @headers_completed = true
            h, data = data.split(/\r\n\r\n/, 2)
            #@headers << h << Crnrn
            if @headers.length > 0
              @headers << h
            else
              @headers = h
            end

            if @headers =~ /Content-[Ll]ength: *([^\r]+)/
              @content_length = $1.to_i
            elsif @headers =~ /Transfer-encoding:\s*chunked/
              @content_length = nil
            else
              @content_length = 0
            end

            # Our Swiftiply Close Header. We are going to look for the <!--SC-> delimeter.
            if @headers =~ /X-Swiftiply-Close:/
              @look_for_close = true
              @packet_length_literal = ""
            end

            if @permit_xsendfile && @headers =~ /X-[Ss]endfile: *([^\r]+)/
              @associate.uri = $1
              if ProxyBag.serve_static_file(@associate, ProxyBag.get_sendfileroot(@associate.name))
                @dont_send_data = true
              else
                if @enable_sendfile_404
                  msg = "#{@associate.uri} could not be found."
                  @associate.send_data "HTTP/1.1 404 Not Found\r\nConnection: close\r\n\r\nContent-Type: text/html\r\nContent-Length: #{msg.length}\r\n\r\n#{msg}"
                  @associate.close_connection_after_writing
                  @dont_send_data = true
                else
                  #put "Writing Headers"
                  #p @headers+Crnrn
                  @associate.send_data @headers + Crnrn
                end
              end
            else
              #put "Writing Headers"
              #p @headers+Crnrn
              @associate.send_data @headers + Crnrn
            end

            # If keepalive is turned on, the assumption is that it will stay
            # on, unless the headers being returned indicate that the connection
            # should be closed.
            # So, check for a 'Connection: Closed' header.
            #put "Keep-Alive is #{@associate.keepalive}"
            if keepalive = @associate.keepalive
              keepalive = false if @headers =~ /Connection: [Cc]lose/
              if @associate_http_version == C1_0
                keepalive = false unless @headers == /Connection: [Kk]eep-[Aa]live/i
              end
              puts "Keep-Alive is reset to #{keepalive}"
            end
            puts "#{__id__}:START ka=#{keepalive} cl=#{@content_length}"
          else
            @headers << data
          end
        end

        if @headers_completed
          # We have sent the headers and separator already. Keep sending any counted content.
          # Content-Length: 0 is handled below.
          if @content_length && @content_length > 0 && @content_sent + data.length >= @content_length
            # We obviously can do below with less statements, but for sanity sake of somebody reading it...
            send_data_length = @content_length - @content_sent
            last_index = send_data_length - 1
            if ! @dont_send_data
              @associate.send_data data[0..last_index]
            end
            # We've sent it all @content_sent += send_data_length, i.e.
            @content_sent = @content_length
            subsequent_length = data.length - @content_length
            if subsequent_length > 0
              subsequent_data = data[last_index + 1..data.length - 1]
            else
              # We flag 0 subsequent data as nil for a conditional below.
              subsequent_data = nil
            end
          else
            if @look_for_close
              while data.length > 0 && ! @swiftiply_close do
                if @packet_length_literal && @packet_length_literal.length < 8
                  needed = 8-@packet_length_literal.length
                  @packet_length_literal += data[0..needed-1]
                  data = data[needed..data.length-1]
                end
                if @packet_length_literal && @packet_length_literal.length == 8
                  if @packet_length_literal == "--------"
                    # We have the close
                    @swiftiply_close = true
                    @packet_length = nil
                    @packet_length_literal = nil
                    @packet_received = nil
                    subsequent_data = data if data.length > 0
                    break # out of while data.length > 0 && ! @swiftiply_close do
                  else
                    @packet_length = @packet_length_literal.to_i
                    @packet_length_literal = nil
                    @packet_received = 0
                  end
                end
                if @packet_length
                  if @packet_received < @packet_length
                    needed = @packet_length - @packet_received
                    if data.length <= needed
                      @packet_received += data.length
                      @associate.send_data data unless @dont_send_data
                      @content_sent += data.length
                      data = ""
                    else
                      tdata = data[0..needed-1]
                      @packet_received += needed
                      @associate.send_data tdata unless @dont_send_data
                      @content_sent += tdata.length
                      data = data[needed..data.length-1]
                    end
                  end
                  if @packet_received == @packet_length
                    @packet_length = nil
                    @packet_length_literal = ""
                  end
                end
              end
            else
              @associate.send_data data unless @dont_send_data
              #put "Sending chunk of #{data.length}"
              subsequent_data = nil
              @content_sent += data.length
            end
          end
          # Check to see if we are done.
          # A Content-Length: 0 means that either no data is to be sent, or it is all to be sent
          # before the connection closes.   # @content_length of nil, means we are chunking.
          # We keep doing that util we find a @swiftiply_close, or something bad happens.

          #put "headers_completed2 #{id} content_length #{@content_length} - sent #{@content_sent} close #{@swiftiply_close} data.length #{data.length} subsequent_data.length #{subsequent_data ? subsequent_data.length : "nil"}"
          if @content_length && !@look_for_close && @content_sent >= @content_length || @swiftiply_close
            puts "#{__id__}:done ka=#{keepalive} cl=#{@content_length} cs=#{@content_sent} #{@swiftiply_close ? "Swifty Closed " : "" }#{@headers[0..60].inspect}"
            # If @dont_send_data is set, then the connection is going to be closed elsewhere.
            unless @dont_send_data
              # Check to see if keepalive is enabled.
              if keepalive
                @associate.reset_state
                ProxyBag.remove_client(self) unless @associate
              else
                @associate.close_connection_after_writing
              end
            end
            @look_for_close = @swiftiply_close = false
            setup
            if subsequent_data && keepalive
              puts "subsequent data: #{subsequent_data.length} ka=#{keepalive}"
              self.receive_data(subsequent_data)
            else
              @associate = nil
              ProxyBag.add_server self
            end
          end
        end
          # TODO: Log these errors!
      rescue Exception => e
        puts "Kaboom: #{e} -- #{e.backtrace.inspect}"
        @associate.close_connection_after_writing if @associate
        @associate = nil
        setup
        ProxyBag.add_server self
      end

      # This is called when the backend disconnects from the proxy.
      # If the backend is currently associated with a web browser client,
      # that connection will be closed.  Otherwise, the backend will be
      # removed from the ProxyBag's backend queue.

      def unbind
        puts "Unbound from Backend!"
        if @associate
          if !@associate.redeployable or @content_length
            @associate.close_connection_after_writing
          else
            @associate.associate = nil
            @associate.setup_for_redeployment
            ProxyBag.rebind_frontend_client(@associate)
          end
        else
          ProxyBag.remove_server(self)
        end
        ProxyBag.remove_id(self)
      end

      def self.bname=(val)
        @bname = val
      end

      def self.bname
        @bname
      end

      def self.xsendfile=(val)
        @xsendfile = val
      end

      def self.xsendfile
        @xsendfile
      end

      def self.enable_sendfile_404=(val)
        @enable_sendfile_404 = val
      end

      def self.enable_sendfile_404
        @enable_sendfile_404
      end

      def self.filter=(val)
        @filter = val
      end

      def self.filter
        @filter
      end

      def filter
        @filter
      end
    end

  end
end
