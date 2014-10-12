require 'fiber'
require 'coroutines/sink'
require 'lazy_enumerator' unless defined? Enumerator::Lazy

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
	#   trans.in_connect(enum)         -> lazy_enumerator
	#
	# In the first form, creates a new Transformer that has the input of
	# +trans+ connected to the output of +other_trans+.
	#
	# In the second form, creates a new lazy Enumerator by connecting the
	# output of +enum+ to the input of +trans+. See Transformer for details.
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
		end.lazy

		description = "#<Enumerator::Lazy: #{inspect} <= #{source.inspect}>"
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

		def count
			Consumer.new do |y|
				yy = Yielder.new y
				n = 0
				yy.define_yield do |*values|
					n += 1
					yy
				end
				@trans.call yy
				n
			end
		end

		def drop(n)
			Transformer.new do |y|
				yy = Yielder.new y
				to_drop = n
				yy.define_yield do |*values|
					if to_drop > 0
						to_drop -= 1
					else
						y.yield(*values)
					end
					yy
				end
				@trans.call yy
			end
		end

		def drop_while(&block)
			Transformer.new do |y|
				yy = Yielder.new y
				dropping = true
				yy.define_yield do |*values|
					if dropping
						if not block.call(*values)
							dropping = false
							y.yield(*values)
						end
					else
						y.yield(*values)
					end
					yy
				end
				@trans.call yy
			end
		end

		def each(&block)
			Consumer.new do |y|
				yy = Yielder.new y
				yy.define_yield do |*values|
					block.call(*values)
					yy
				end
				@trans.call yy
			end
		end

		def filter_map(&block)
			Transformer.new do |y|
				yy = Yielder.new y
				yy.define_yield do |*values|
					x = block.call(*values)
					y.yield(x) unless x.nil?
					yy
				end
				@trans.call yy
			end
		end

		def flat_map(&block)
			Transformer.new do |y|
				yy = Yielder.new y
				yy.define_yield do |*values|
					x = block.call(*values)
					if x.respond_to? :to_ary
						x.to_ary.each{|xx| y.yield xx }
					else
						y.yield x
					end
					yy
				end
				@trans.call yy
			end
		end
		alias_method :collect_concat, :flat_map

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

		def reduce(*args)
			if not block_given?
				if args.size == 1
					return reduce(&args[0].to_proc)
				elsif args.size == 2
					return reduce(args[0], &args[1].to_proc)
				else
					raise ArgumentError, "wrong number of arguments"
				end
			end
			raise ArgumentError, "wrong number of arguments" if args.size > 1
			block = proc

			memo = if args.empty? then nil else args[0] end
			Consumer.new do |y|
				yy = Yielder.new y
				yy.define_yield do |value|
					if memo.nil?
						memo = value
					else
						memo = block.call memo, value
					end
					yy
				end
				@trans.call yy
				memo
			end
		end
		alias_method :inject, :reduce

		def reject(&block)
			Transformer.new do |y|
				yy = Yielder.new y
				yy.define_yield do |*values|
					y.yield(*values) unless block.call(*values)
					yy
				end
				@trans.call yy
			end
		end

		def select(&block)
			Transformer.new do |y|
				yy = Yielder.new y
				yy.define_yield do |*values|
					y.yield(*values) if block.call(*values)
					yy
				end
				@trans.call yy
			end
		end

		def take(n)
			Transformer.new do |y|
				yy = Yielder.new y
				to_take = n
				yy.define_yield do |*values|
					if to_take > 0
						y.yield(*values)
						to_take -= 1
					else
						raise StopIteration
					end
					yy
				end
				@trans.call yy
			end
		end

		def take_while(&block)
			Transformer.new do |y|
				yy = Yielder.new y
				yy.define_yield do |*values|
					if block.call(*values)
						y.yield(*values)
					else
						raise StopIteration
					end
					yy
				end
				@trans.call yy
			end
		end

		def sort
			Consumer.new do |y|
				yy = Yielder.new y
				result = []
				yy.define_yield do |value|
					result << value
					yy
				end
				@trans.call yy
				result.sort
			end
		end

		def sort_by(&block)
			Consumer.new do |y|
				yy = Yielder.new y
				result = []
				yy.define_yield do |value|
					result << value
					yy
				end
				@trans.call yy
				result.sort_by(&block)
			end
		end

		def to_a
			Consumer.new do |y|
				yy = Yielder.new y
				result = []
				yy.define_yield do |value|
					result << value
					yy
				end
				@trans.call yy
				result
			end
		end

		def to_h
			Consumer.new do |y|
				yy = Yielder.new y
				result = {}
				yy.define_yield do |value|
					result[value[0]] = value[1]
					yy
				end
				@trans.call yy
				result
			end
		end
	end

	# :call-seq:
	#    trans.lazy -> lazy_trans
	#
	# Returns a "lazy enumeration like" transformer. More precisely, the object
	# returned can in many situations be used as if it were an Enumerator
	# returned by trans.in_connect, since it implements work-alikes of many
	# Enumerable methods. Note however that the return types of those methods
	# differ: where an Enumerator method would return a new Enumerator, the
	# corresponding lazy transformer returns a new Transformer; where an
	# Enumerator would return a single value, the lazy transformer returns a
	# Consumer.
	#
	# Example:
	#
	#   running_sum = Transformer.new do |y|
	#     result = 0
	#     loop { result += y.await; y.yield result }
	#   end
	#
	#   sum_str = running_sum.lazy.map{|x| x.to_s}
	#   # => a Transformer
	#   (1..10).out_connect(sum_str).to_a
	#   # => ["1", "3", "6", "10", "15", "21", "28", "36", "45", "55"]
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

