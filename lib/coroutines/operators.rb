require 'coroutines/base'

module Enumerable
	# :call-seq:
	#   enum >= sink  -> obj
	#   enum >= trans -> new_enum
	#
	# In the first form, iterate over +enum+ and write each result to +sink+
	# using <<; then return the result of sink.close.
	#
	# In the second form, create a new Enumerator by connecting the output of
	# +enum+ to the input of +trans+ (which must be convertible to a
	# Transformer using the to_trans method).
	def >=(other)
		if other.respond_to? :<<
			begin
				each { |x| other << x }
			rescue StopIteration
			end
			other.close
		elsif other.respond_to? :to_trans
			other <= self
		end
	end
end

module Sink
	# :call-seq:
	#   sink <= enum  -> obj
	#   sink <= trans -> new_consum
	#
	# In the first form, iterate over +enum+ and write each result to +sink+
	# using <<; then return the result of sink.close.
	#
	# In the second form, create a new Consumer by connecting the output of
	# +trans+ (which must be convertible to a Transformer using the
	# to_trans method) to the input of +sink+.
	def <=(other)
		if other.respond_to? :each
			begin
				other.each { |x| self << x }
			rescue StopIteration
			end
			close
		elsif other.respond_to? :to_trans
			other >= self
		end
	end
end

class Transformer
	alias_method :<=, :in_connect
	alias_method :>=, :out_connect
end

class Symbol
	# :call-seq:
	#   sym.to_trans -> transformer
	#
	# Allows implicit conversion of Symbol to Transformer. The transformer
	# accepts any objects as input, calls the method given by +sym+ on each and
	# outputs all non-nil results of the method. See Proc#to_trans for details.
	#
	# example:
	#
	#   collector = [] <= :to_s
	#   collector << 1 << 4 << 9
	#   collector.close # => ["1", "4", "9"]
	#
	def to_trans
		Transformer.new do |y|
			loop do
				value = y.await.send self
				y.yield value unless value.nil?
			end
		end
	end

	# :call-seq:
	#   sym <= trans  -> new_trans
	#   sym <= enum   -> new_enum
	#
	# Equivalent to sym.to_trans <= trans/enum, except that it uses a more
	# efficient implementation.
	def <=(source)
		to_proc <= source
	end

	# :call-seq:
	#   sym >= trans  -> new_trans
	#   sym >= sink   -> new_consumer
	#
	# Equivalent to sym.to_trans >= trans/sink, except that it uses a more
	# efficient implementation.
	def >=(sink)
		to_proc >= sink
	end
end

class Proc
	# :call-seq:
	#   proc.to_trans -> transformer
	#
	# Allows implicit conversion of Proc to Transformer. The transformer is a
	# combination of map and filter over its input values: For each input
	# value, +proc+ is called with the input value as parameter. Every non-nil
	# value returned by +proc+ is yielded as an output value.
	#
	# This is similar to Enumerable#map followed by Array#compact, but without
	# constructing the intermediate Array (so it's even more similar to
	# something like enum.lazy.map(&proc).reject(&:nil?), using the lazy
	# enumerator introduced in Ruby 2.0).
	#
	# Example:
	#
	#   (1..10) >= proc{|x| x.to_s + ", " if x.even? } >= ""
	#   # => "2, 4, 6, 8, 10, "
	#
	def to_trans
		Transformer.new do |y|
			loop do
				value = self.call(y.await)
				y.yield value unless value.nil?
			end
		end
	end

	# :call-seq:
	#   proc <= trans  -> new_trans
	#   proc <= enum   -> new_enum
	#
	# Equivalent to proc.to_trans <= trans/enum, except that it uses a more
	# efficient implementation.
	def <=(source)
		if source.respond_to? :each
			Enumerator.new do |y|
				source.each do |obj|
					value = call obj
					y << value unless value.nil?
				end
			end.lazy
		elsif source.respond_to? :to_proc
			sp = source.to_proc
			proc do |*args|
				value = sp.call(*args)
				if value.nil? then nil else self.call value end
			end
		elsif source.respond_to? :to_trans
			# FIXME: this could be implemented more efficiently; proc doesn't
			#        need to run in a separate Fiber
			self.to_trans <= source.to_trans
		else
			raise ArgumentError, "#{source.inspect} is neither an enumerable nor a transformer"
		end
	end

	# :call-seq:
	#   proc >= trans  -> new_trans
	#   proc >= sink   -> new_consumer
	#
	# Equivalent to proc.to_trans >= trans/sink, except that it uses a more
	# efficient implementation.
	def >=(sink)
		if sink.respond_to? :input_map
			sink.input_reject(&:nil?).input_map(&self)
		elsif sink.respond_to? :to_proc
			sp = sink.to_proc
			proc do |*args|
				value = self.call(*args)
				if value.nil? then nil else sp.call value end
			end
		elsif sink.respond_to? :to_trans
			# FIXME: this could be implemented more efficiently; proc doesn't
			#        need to run in a separate Fiber
			self.to_trans >= sink.to_trans
		else
			raise ArgumentError, "#{sink.inspect} is neither a sink nor a transformer"
		end
	end
end
