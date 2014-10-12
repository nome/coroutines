require 'coroutines'
require 'date'

# Example shamelessly stolen from
# http://www.dabeaz.com/generators

class String
	def to_datetime
		DateTime.parse(sub(":", "T"))
	end
end

COLNAMES = %w{host referrer user datetime    method request proto status bytes}
COLTYPES = %w{to_s to_s     to_s to_datetime to_s   to_s    to_s  to_i   to_i }.map(&:to_sym)

def parse
	loop do
		if await =~ /(\S+) (\S+) (\S+) \[(.*?)\] "(\S+) (\S+) (\S+)" (\S+) (\S+)/
			log_entry = $~.captures.zip(COLNAMES, COLTYPES).
				map{|val, name, type| [name, val.send(type)] }.
				out_connect(Hash.new)
			yield log_entry
		end
	end
end

def find_404
	loop do
		r = await
		if r["status"] == 404
			yield %w{status datetime request}.map{|col| r[col].to_s}.join(" ")
		end
	end
end

def dump(label)
	loop do
		puts "#{label}: #{await}"
	end
end

def bytes_transferred
	total = 0
	loop do
		total += await["bytes"]
		yield total
	end
end

def request_rate
	last = await["datetime"]
	loop do
		n = 0
		begin
			this = await["datetime"]
			n += 1
		end while this == last
		yield n.to_f / (this - last).to_f
		last = this
	end
end

open("/var/log/apache2/access.log").
	out_connect(trans_for :parse).
	out_connect(Multicast.new(
		trans_for(:find_404).         out_connect(consum_for(:dump, "404        ")),
		trans_for(:bytes_transferred).out_connect(consum_for(:dump, "Total bytes")),
		trans_for(:request_rate).     out_connect(consum_for(:dump, "Requests/s "))
	)
)

