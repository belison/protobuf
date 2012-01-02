require 'protobuf/rpc/connectors/base'
require 'protobuf/rpc/connectors/em_client'

module Protobuf
  module Rpc
    module Connectors
      class EventMachine < Base
        include Protobuf::Logger::LogMethods
        include Protobuf::Rpc::Connectors::Common
        include Eventually
        enable_strict!
        emits :success, :arity => 1
        emits :failure, :arity => 1
        emits :complete, :arity => 1
        
        def send_request
          ensure_em_running do 
            f = Fiber.current
 
            EM.schedule do
              log_debug "[#{log_signature}] Scheduling EventMachine client request to be created on next tick"
              cnxn = EMClient.connect(options, &ensure_cb)
              cnxn.on(:success) {|response| emit(:success, response) }
              cnxn.on(:failure) {|error| emit(:failure, error) }
              cnxn.on(:complete) do |obj|
                resume_fiber(f) unless async?
                emit(:complete, obj)
              end
              log_debug "[#{log_signature}] Connection scheduled"
            end

            async? ? true : set_timeout_and_validate_fiber
          end
        end
        
        # Returns a callable that ensures any errors will be returned to the client
        # 
        # If a failure callback was set, just use that as a direct assignment
        # otherwise implement one here that simply throws an exception, since we
        # don't want to swallow the black holes.
        # 
        def ensure_cb
          @ensure_cb ||= (@failure_cb || lambda { |error| raise '%s: %s' % [error.code.name, error.message] } )
        end

        def log_signature
          @log_signature ||= "client-#{self.class}"
        end
      
        private

        def ensure_em_running(&blk)
          EM.reactor_running? ? yield : EM.fiber_run { blk.call; EM.stop }
        end

        def resume_fiber(fib)
          EM::cancel_timer(@timeout_timer)
          fib.resume(true)
        rescue => ex 
          log_error "[#{log_signature}] An exception occurred while waiting for server response:"
          log_error ex.message
          log_error ex.backtrace.join("\n")

          message = 'Synchronous client failed: %s' % ex.message
          err = Protobuf::Rpc::Connectors::Common::ClientError.new(Protobuf::Socketrpc::ErrorReason::RPC_ERROR, message)
          ensure_cb.call(err)
        end

        def set_timeout_and_validate_fiber
          @timeout_timer = EM::add_timer(@options[:timeout]) do
            message = 'Client timeout of %d seconds expired' % @options[:timeout]
            err = Protobuf::Rpc::Connectors::Common::ClientError.new(Protobuf::Socketrpc::ErrorReason::RPC_ERROR, message)
            ensure_cb.call(err)
          end

          Fiber.yield
        rescue FiberError
          message = "Synchronous calls must be in 'EM.fiber_run' block" 
          err = Protobuf::Rpc::Connectors::Common::ClientError.new(Protobuf::Socketrpc::ErrorReason::RPC_ERROR, message)
          ensure_cb.call(err)
        end

      end
    end
  end
end