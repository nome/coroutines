# The <code>Sink</code> mixin provides classes that can accept streams of
# values with several utility methods. Classes using this mixin must at least
# provide an operator << which accepts a value and returns the sink instance
# (allowing chaining). Optionally, the class may provide a close method that
# signals end of input and (also optionally) retrives a result value.
module Sink
	# May be overriden by classes using the Sink mixin. The default
	# implementation just returns self.
	def close
		self
	end

	# :call-seq:
	#   sink.in_connect(enum)  -> obj
	#   sink.in_connect(trans) -> new_consum
	#
	# In the first form, iterate over +enum+ and write each result to +sink+
	# using <<; then return the result of sink.close.
	#
	# In the second form, create a new Consumer by connecting the output of
	# +trans+ (which must be convertible to a Transformer using the
	# to_trans method) to +sink+.
	def in_connect(other)
		if other.respond_to? :each
			begin
				other.each { |x| self << x }
			rescue StopIteration
			end
			close
		elsif other.respond_to? :to_trans
			other.to_trans.out_connect(self)
		end
	end

	# :call-seq:
	#   sink.input_map{ |obj| block } -> new_sink
	#
	# Returns a new sink which supplies each of its input values to the given
	# block and feeds each result of the block to +sink+.
	def input_map(&block)
		InputMapWrapper.new(self, &block)
	end

	# :call-seq:
	#   sink.input_select{ |obj| block } -> new_sink
	#
	# Returns a new sink which feeds those inputs for which +block+ returns a
	# true value to +sink+ and discards all others.
	def input_select
		InputSelectWrapper.new(self, &block)
	end

	# :call-seq:
	#   sink.input_reject{ |obj| block } -> new_sink
	#
	# Returns a new sink which feeds those inputs for which +block+ returns a
	# false value to +sink+ and discards all others.
	def input_reject(&block)
		InputRejectWrapper.new(self, &block)
	end

	# :call-seq:
	#   sink.input_reduce(initial=nil){ |memo, obj| block } -> new_sink
	#
	# Returns a new sink which reduces its input values to a single value, as
	# in Enumerable#reduce.  When +new_sink+ is closed, the reduced value is
	# fed to +sink+ and +sink+ is closed as well.
	def input_reduce(*args, &block)
		InputReduceWrapper.new(self, *args, &block)
	end

	# Collects multiple sinks into a multicast group. Every input value of the
	# multicast group is supplied to each of its members. When the multicast
	# group is closed, all members are closed as well.
	class Multicast
		def initialize(*receivers)
			@receivers = receivers
		end
		def <<(obj)
			@receivers.each { |r| r << obj }
			self
		end
		def close
			@receivers.each(&:close)
		end
		include Sink
	end

	######################################################################
	private
	######################################################################

	class InputWrapper
		def initialize(target, &block)
			@target = target; @block = block
		end
		def close
			@target.close
		end
		include Sink
	end

	class InputMapWrapper < InputWrapper
		def <<(args)
			@target << @block.call(args)
		end
		def inspect
			"#<#{@target.inspect}#input_map>"
		end
	end

	class InputSelectWrapper < InputWrapper
		def <<(args)
			@target << args if @block.call(args)
		end
		def inspect
			"#<#{@target.inspect}#select>"
		end
	end

	class InputRejectWrapper < InputWrapper
		def <<(args)
			@target << args unless @block.call(args)
		end
		def inspect
			"#<#{@target.inspect}#reject>"
		end
	end

	class InputReduceWrapper
		def initialize(target, initial=nil, &block)
			@target = target; @block = block
			@memo = initial
		end
		def <<(arg)
			if @memo.nil?
				@memo = arg
			else
				@memo = @block.call(@memo, arg)
			end
			self
		end
		def close
			@target << @memo
			@target.close
		end
		include Sink
	end
end
