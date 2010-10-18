require 'ladle'

module Ladle
  ##
  # Controller for Ladle's core feature, the embedded LDAP server.
  class Server
    ##
    # The port from which this server will be available.
    # @return [Fixnum]
    attr_reader :port

    ##
    # The domain for the served data.
    # @return [String]
    attr_reader :domain

    ##
    # The filename of the LDIF data loaded into this server before it
    # started.
    # @return [String]
    attr_reader :ldif

    ##
    # The time to wait for the server to start up before giving up
    # (seconds).
    # @return [Fixnum]
    attr_reader :timeout

    ##
    # @param [Hash] opts the options for the server
    # @option opts [Fixnum] :port (3897) The port to serve from.
    # @option opts [String] :ldif ({path to the gem}/lib/ladle/default.ldif)
    #   The filename of the LDIF-formatted data to use for this
    #   server.  If provide your own data, be sure to set the
    #   :domain option to match.
    # @option opts [String] :domain ("dc=example,dc=org") the domain
    #   for the data provided in the :ldif option.
    # @option opts [Boolean] :verbose (false) if true, detailed
    #   information about the execution of the server will be printed
    #   to standard error.
    # @option opts [Boolean] :quiet (false) if true _no_ information
    #   about regular execution will be printed.  Error information
    #   will still be printed.  This trumps `:verbose`.
    # @option opts [Fixnum] :timeout (15) the amount of time to wait
    #   (seconds) for the server process to start before giving up.
    def initialize(opts={})
      @port = opts[:port] || 3897
      @domain = opts[:domain] || "dc=example,dc=org"
      @ldif = opts[:ldif] || File.expand_path("../default.ldif", __FILE__)
      @quiet = opts[:quiet]
      @verbose = opts[:verbose]
      @timeout = opts[:timeout] || 15

      # Additional arguments that can be passed to the java server
      # process.  Used for testing only, so not documented.
      @additional_args = opts[:more_args] || []

      unless @domain =~ /^dc=/
        raise "The domain component must start with 'dc='.  '#{@domain}' does not."
      end

      unless File.readable?(@ldif)
        raise "Cannot read specified LDIF file #{@ldif}."
      end
    end

    ##
    # Starts up the server in a separate process.  This method will
    # not return until the server is listening on the specified port.
    # The same {Server} instance can be started and stopped multiple
    # times, but the runs will be independent.
    #
    # @return [Server] this instance
    def start
      return if @running
      log "Starting server on #{port}"
      trace "- Server command: #{server_cmd}"
      @pid, java_in, java_out, java_err = strategy.popen4(server_cmd)
      @running = true

      @log_watcher = LogStreamWatcher.new(java_err, self)
      @log_watcher.start
      @controller = ApacheDSController.new(java_in, java_out, self)
      @controller.start

      trace "- Waiting for server to start"
      started_waiting = Time.now
      until @controller.started? || @controller.error? || Time.now > started_waiting + timeout
        trace "- #{Time.now - started_waiting} seconds elapsed"
        sleep 0.5
      end
      trace "- Stopped waiting after #{Time.now - started_waiting} seconds"

      if @controller.error?
        self.stop
        raise "LDAP server failed to start"
      elsif !@controller.started?
        self.stop
        trace "- Timed out"
        raise "LDAP server startup did not complete within #{timeout} seconds"
      end

      trace "- Server started successfully"
      at_exit { stop }

      self
    end

    ##
    # Stops the server that was started with {#start}.
    def stop
      return if !@running
      log "Stopping server on #{port}"
      trace "- stopping server process"
      @controller.stop if @controller
      trace "- stopping log watcher"
      @log_watcher.stop if @log_watcher

      if @pid
        trace "- killing server process #{@pid} (if not already stopped)"
        begin
          Process.kill "TERM", @pid
          trace "  * term sent"
          Process.waitpid2 @pid
          trace "  * gone"
        rescue Errno::ESRCH
          trace "  * was already dead"
        end
      end

      @running = false
    end

    ##
    # Visible for collaborators.
    # @private
    def log_error(msg)
      $stderr.puts(msg)
    end

    ##
    # Visible for collaborators.
    # @private
    def log(msg)
      $stderr.puts(msg) unless quiet?
    end

    ##
    # Visible for collaborators.
    # @private
    def trace(msg)
      $stderr.puts(msg) if verbose? && !quiet?
    end

    ##
    # If the controller will print anything about what it is doing to
    # stderr.  If this is true, all non-error output will be
    # supressed.  This value trumps {#verbose?}.
    #
    # @return [Boolean]
    def quiet?
      @quiet
    end

    ##
    # Whether the controller will print detailed information about
    # what it is doing to stderr.  This includes information from the
    # embedded ApacheDS instance.
    #
    # @return [Boolean]
    def verbose?
      @verbose
    end

    def strategy
      Ladle::RubyAdapter
    end

    private

    def server_cmd
      ([
        "java",
        "-cp", classpath,
        "net.detailedbalance.ladle.Main"
      ] + @additional_args).join(' ')
    end

    def classpath
      (
        # ApacheDS
        Dir[File.expand_path("../apacheds/*.jar", __FILE__)] +
        # Wrapper code
        [File.expand_path("../java", __FILE__)]
      ).join(':')
    end

    ##
    # Encapsulates communication with the child ApacheDS process.
    class ApacheDSController
      def initialize(ds_in, ds_out, server)
        @ds_in = ds_in
        @ds_out = ds_out
        @server = server
      end

      def start
        Thread.new(self) do |controller|
          controller.watch
        end
      end

      def watch
        while (line = @ds_out.readline) && !error?
          case line
          when /^STARTED/
            @started = true
          when /^FATAL/
            report_error(line)
          when /^STOPPED/
            @started = false
          else
            report_error("Unexpected server process output: #{line}")
          end
        end
      end

      def started?
        @started
      end

      def error?
        @error
      end

      def stop
        unless @ds_in.closed?
          @ds_in.puts("STOP")
          @ds_in.flush
          @ds_in.close
        end
        @ds_out.close unless @ds_out.closed?
      end

      private

      def report_error(msg)
        @error = true
        @server.log_error "ApacheDS process failed: #{msg}"
        self.stop
      end
    end

    class LogStreamWatcher
      def initialize(ds_err, server)
        @ds_err = ds_err
        @server = server
      end

      def start
        Thread.new(self) do |watcher|
          watcher.watch
        end
      end

      def watch
        begin
          while !@ds_err.closed? && (line = @ds_err.readline)
            if is_error?(line)
              @server.log_error("ApacheDS: #{line}")
            else
              @server.trace("ApacheDS: #{line}")
            end
          end
        rescue EOFError
          # stop naturally
        end
      end

      def stop
        @ds_err.close unless @ds_err.closed?
      end

      private

      def is_error?(line)
        kind = (line =~ /^([A-Z]+):/) ? $1 : nil
        (kind.nil? || %w(ERROR WARN).include?(kind)) && !bogus?(line)
      end

      ##
      # Indicates whether the "error" or "warning" emitted from
      # ApacheDS is actually an error or warning.
      def bogus?(line)
        [
          %r{shutdown hook has NOT been registered},
          %r{attributeType w/ OID 2.5.4.16 not registered}
        ].detect { |re| line =~ re }
      end
    end
  end
end
