require 'fiber'
require 'coroutines/sink'

# A class implementing consumer coroutines
#
# A Consumer can be created by the following methods:
# * Object#consum_for
# * Object#consumer
# * Consumer.new
# * Transformer#out_connect
#
# See Object#consum_for for an explanation of the basic concepts.
class Consumer
	class Yielder
		if Fiber.instance_methods.include? :raise
			def await
				Fiber.yield
			end
		else
			@@exception_wrapper = Class.new do
				define_method :initialize do |*args|
					@args = args
				end
				attr_reader :args
			end

			def await
				item = Fiber.yield
				raise(*item.args) if item.instance_of? @@exception_wrapper
				return item
			end
		end
	end

	# :call-seq:
	#   Consumer.new { |yielder| ... } -> consumer
	#
	# Creates a new Consumer coroutine, which can be used as a Sink.
	#
	# The block is called immediately with a "yielder" object as parameter.
	# +yielder+ can be used to retrieve a value from the consumption context by
	# calling its await method.
	#
	#   consum = Consumer.new do |y|
	#     a = y.await
	#     b = y.await
	#     "#{a} + #{b} = #{a + b}"
	#   end
	#
	#   consum << 42 << 24
	#   consum.close  # => "42 + 24 = 66"
	#
	def initialize(&block)
		@fiber = Fiber.new(&block)
		@result = nil

		self << Yielder.new
	end

	def inspect
		status = if @fiber.alive? then "running" else @result.inspect end
		"#<Consumer: 0x#{object_id.to_s(16)} (#{status})>"
	end

	# After the consumer has terminated (which may have happened in response to
	# Consumer#close), result contains the value returned by the consumer.
	attr_reader :result

	# :call-seq:
	#   consumer << obj -> consumer
	#
	# Feeds +obj+ as an input to the consumer.
	def <<(obj)
		raise StopIteration unless @fiber.alive?
		value = @fiber.resume(obj)
		@result = value unless @fiber.alive?
		self
	end

	if Fiber.instance_methods.include? :raise
		# :call-seq:
		#   consumer.close -> obj
		#
		# Terminate the consumer by raising StopIteration at the point where it
		# last requested an input value. +obj+ is the return value of the consumer.
		def close
			@result = @fiber.raise StopIteration if @fiber.alive?
			return @result
		rescue StopIteration
			return @result
		end
	else
		def close
			wrapper = Yielder.class_variable_get(:@@exception_wrapper)
			@result = @fiber.resume(wrapper.new(StopIteration)) if @fiber.alive?
			return @result
		rescue StopIteration
			return @result
		end
	end

	include Sink
end

# A class implementing transformer coroutines
#
# A Transformer can be created by the following methods:
# * Object#trans_for
# * Transformer.new
#
# Transformers are pieces of code that accept input values and produce output
# values (without returning from their execution context like in a regular
# method call). They are used by connecting either their input to an enumerable
# or their output to a sink (or both, using Sink#in_connect or
# Enumerable#out_connect). An enumerable is any object implementing an iterator
# method each; a sink is any object implementing the << operator (which is
# assumed to store or output the supplied values in some form).
#
# The input of a transformer is connected to an enumerable +enum+ using
# trans.in_connect(enum), the result of which is a new Enumerator instance. The
# transformer is started upon iterating over this Enumerator. Whenever the
# transformer requests a new input value (see Object#trans_for and
# Transformer#new for how to do this), iteration over +enum+ is resumed. The
# output values of the transformer (again, see Object#trans_for and
# Transformer#new) are yielded by the enclosing Enumerator.  When +enum+ is
# exhausted, StopIteration is raised at the point where the transformer last
# requested an input value. It is expected that the transformer will then
# terminate without requesting any more values (though it may execute e.g. some
# cleanup actions).
#
# The output of a transformer is connected to a sink using
# trans.out_connect(sink), the result of which is a new Consumer instance. The
# transformer starts executing right away; when it requests its first input
# value, out_connect returns. Input values supplied using << to the enclosing
# Consumer are forwarded to the transformer by resuming execution at the point
# where it last requested an input value. Output values produced by the
# transformer are fed to sink#<<. After terminating, the result of the new
# Consumer is the value returned by sink.close (see Consumer#result and
# Consumer#close).
#
# Transformers can also be chained together by connecting the output of one the
# input the next using trans.out_connect(other_trans) or
# trans.in_connect(other_trans). See Transformer#out_connect and
# Transformer#in_connect for details.
#
class Transformer
	# :call-seq:
	#   Transformer.new { |yielder| ... } -> trans
	#
	# Creates a new Transformer coroutine defined by the given block.
	#
	# The block is called with a "yielder" object as parameter. +yielder+ can
	# be used to retrieve a value from the consumption context by calling its
	# await method (as in Consumer.new), and to yield a value by calling
	# its yield method (as in Enumerator.new).
	#
	#   running_sum = Transformer.new do |y|
	#     result = 0
	#     loop { result += y.await; y.yield result }
	#   end
	# 
	#   (1..3).out_connect(running_sum).out_connect([])  # => [1, 3, 6]
	#
	def initialize(&block)
		@self = block
	end

	def inspect
		"#<Transformer: 0x#{object_id.to_s(16)}>"
	end

	# :call-seq:
	#   transformer.to_trans  -> transformer
	#
	# Returns self.
	def to_trans
		self
	end

	# :call-seq:
	#   trans.in_connect(other_trans)  -> new_trans
	#   trans.in_connect(enum)         -> new_enum
	#
	# In the first form, creates a new Transformer that has the input of
	# +trans+ connected to the output of +other_trans+.
	#
	# In the second form, creates a new Enumerator by connecting the output of
	# +enum+ to the input of +trans+. See Transformer for details.
	def in_connect(source)
		if not source.respond_to? :each
			return source.to_trans.transformer_chain self
		end

		source_enum = source.to_enum
		enum = Enumerator.new do |y|
			y.define_singleton_method :await do
				source_enum.next
			end
			@self.call(y)
		end

		description = "#<Enumerator: #{inspect} <= #{source.inspect}>"
		enum.define_singleton_method :inspect do
			description
		end

		enum
	end

	# :call-seq:
	#   trans.out_connect(other_trans)  -> new_trans
	#   trans.out_connect(sink)         -> consum
	#
	# In the first form, creates a new Transformer that has the output of
	# +trans+ connected to the input of +other_trans+.
	#
	# In the second form, creates a new Consumer by connecting the output of
	# +trans+ to the input of +sink+. See Transformer for details.
	def out_connect(sink)
		if not sink.respond_to? :<<
			return transformer_chain sink.to_trans
		end

		consum = Consumer.new do |y|
			y.define_singleton_method :yield do |args|
				sink << args
				y
			end
			y.singleton_class.instance_eval { alias_method :<<, :yield }
			begin
				@self.call(y)
			rescue StopIteration
			end
			sink.close
		end

		description = "#<Consumer: #{inspect} >= #{sink.inspect}>"
		consum.define_singleton_method :inspect do
			description
		end

		consum
	end

	class Lazy
		def initialize(trans)
			@trans = trans.instance_variable_get :@self
		end

		def lazy
			self
		end

		class Yielder
			def initialize(wrapped)
				@wrapped = wrapped
			end
			def await
				@wrapped.await
			end

			def define_yield(&block)
				singleton_class.instance_eval do
					define_method(:yield, &block)
					alias_method :<<, :yield
				end
			end
		end

		def map(&block)
			Transformer.new do |y|
				yy = Yielder.new y
				yy.define_yield do |*values|
					y.yield(block.call(*values))
					yy
				end
				@trans.call yy
			end
		end
		alias_method :collect, :map

		def out_connect(other)
			Transformer.new(&@trans).out_connect(other)
		end

	end

	def lazy
		Lazy.new self
	end

	protected

	class FirstYielder < Consumer::Yielder
		if Fiber.instance_methods.include? :raise
			def await
				Fiber.yield(:await)
			end
			def yield(*args)
				Fiber.yield(:yield, *args)
				self
			end
			alias_method :<<, :yield
		else
			def await
				item = Fiber.yield(:await)
				raise(*item.args) if item.instance_of? @@exception_wrapper
				return item
			end
			def yield(*args)
				item = Fiber.yield(:yield, *args)
				raise(*item.args) if item.instance_of? @@exception_wrapper
				self
			end
			alias_method :<<, :yield
		end
	end

	class SecondYielder < Consumer::Yielder
		def initialize(y, fiber)
			@y, @fiber = y, fiber
		end

		if Fiber.instance_methods.include? :raise
			def await
				raise StopIteration unless @fiber.alive?
				tag, result = @fiber.resume
				while tag == :await do
					x = nil
					begin
						x = @y.await
					rescue Exception => e
						tag, result = @fiber.raise(e)
					end
					tag, result = @fiber.resume(*x) unless x.nil?
					raise StopIteration unless @fiber.alive?
				end
				result
			end
		else
			def await
				raise StopIteration unless @fiber.alive?
				tag, result = @fiber.resume
				while tag == :await do
					begin
						x = @y.await
					rescue Exception => e
						x = [@@exception_wrapper.new(e)]
					end
					tag, result = @fiber.resume(*x) if @fiber.alive?
					raise StopIteration unless @fiber.alive?
				end
				result
			end
		end

		def yield(*args)
			@y.yield(*args)
			self
		end
		alias_method :<<, :yield
	end

	def transformer_chain(other)
		first = @self
		second = other.instance_variable_get(:@self)

		trans = Transformer.new do |y|
			fib = Fiber.new { first.call FirstYielder.new }
			second.call(SecondYielder.new y, fib)
		end

		description = "#{inspect} >= #{other.inspect}"
		trans.define_singleton_method :inspect do
			description
		end

		trans
	end
end

