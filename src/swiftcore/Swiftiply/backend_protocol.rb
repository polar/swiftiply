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
        #@content_length = nil
        @content_sent = 0
        @filter       = self.class.filter
      end

      # Receive data from the backend process.  Headers are parsed from
      # the rest of the content.  If a Content-Length header is present,
      # that is used to determine how much data to expect.  Otherwise,
      # if 'Transfer-encoding: chunked' is present, assume chunked
      # encoding.  Otherwise be paranoid; something isn't the way we like
      # it to be.

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
            else
              puts "Unauthenticated Connection"
              # The worker that connected did not present the proper authentication,
              # so something is fishy; time to cut bait.
              close_connection
              return
            end
          rescue Exception => boom
            puts "Bad Data"
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
              #put "Keep-Alive is reset to #{keepalive}"
            end
          else
            @headers << data
          end
        end

        if @headers_completed
          # We have sent the headers and separator already. Keep sending any counted content.
          # Content-Length: 0 is handled below.
          if @content_length && @content_length > 0 && @content_sent + data.length >= @content_length
            @associate.send_data data.slice(0, @content_length - @content_sent) unless @dont_send_data
            subsequent_data = data.slice(@content_length - @content_sent, data.length - @content_sent)
            @content_sent = @content_length
          else
            if @look_for_close
              #put "Looking for <!--SC->"
              tdata = @push_back ? @push_back + data : data
              @push_back = nil
              match = /^([\S\s]*)<!--SC->([\S\s]*)$/.match(tdata)
              if (match)
                #put "Found <!--SC->"
                @associate.send_data match[1] if (match[1].length > 0) unless @dont_send_data
                @content_sent += match[1].length
                subsequent_data = match[2] if match[2].length > 0
                #put "Found <!--SC-> with #{subsequent_data ? subsequent_data.length : "no"} subsequent data"
                @swiftiply_close = true
              else
                # Ugly and Slow
                if tdata.length > 7
                  fdata = tdata.slice(0, tdata.length-7)
                  tdata = tdata.slice(-7, 7)
                else
                  fdata = ""
                end
                if (match = /^([\S\s]*)<!--SC-$/.match(tdata))
                  sdata = fdata + match[1]
                  @push_back = "<!--SC-"
                elsif (match = /^([\S\s]*)<!--SC$/.match(tdata))
                  sdata = fdata + match[1]
                  @push_back = "<!--SC"
                elsif (match = /^([\S\s]*)<!--S$/.match(tdata))
                  sdata = fdata + match[1]
                  @push_back = "<!--S"
                elsif (match = /^([\S\s]*)<!--$/.match(tdata))
                  sdata = fdata + match[1]
                  @push_back = "<!--"
                elsif (match = /^([\S\s]*)<!-$/.match(tdata))
                  sdata = fdata + match[1]
                  @push_back = "<!-"
                elsif (match = /^([\S\s]*)<!$/.match(tdata))
                  sdata = fdata + match[1]
                  @push_back = "<!"
                elsif (match = /^([\S\s]*)<$/.match(tdata))
                  sdata = fdata + match[1]
                  @push_back = "<"
                else
                  tdata = fdata + tdata
                  @push_back = nil
                end
                if @push_back
                  if sdata.length > 0
                    @associate.send_data sdata unless @dont_send_data
                    #put "Sending chunk of #{sdata.length}"
                    @content_sent += sdata.length
                    subsequent_data = nil
                  end
                else
                  @associate.send_data tdata unless @dont_send_data
                  #put "Sending chunk of #{tdata.length}"
                  @content_sent += tdata.length
                  subsequent_data = nil
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
            # If @dont_send_data is set, then the connection is going to be closed elsewhere.
            unless @dont_send_data
              # Check to see if keepalive is enabled.
              if keepalive
                @associate.reset_state
                ProxyBag.remove_client(self) unless @associate
              else
                puts "Closing Connection after write"
                @associate.close_connection_after_writing
              end
            end
            @headers_completed = @dont_send_data = nil
            @look_for_close = @swiftiply_close = false
            @headers      = ''
            #@headers_completed = false
            #@content_length = nil
            @content_sent = 0
            #setup
            if subsequent_data && keepalive
              self.receive_data(subsequent_data)
            else
              puts "Done with request"
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
