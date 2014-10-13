require 'coroutines'
require 'date'

# Example shamelessly stolen from
# http://www.dabeaz.com/generators

class String
	# parse Apache timestamps
	def to_datetime
		DateTime.parse(sub(":", "T"))
	end
end

COLNAMES = %w{host referrer user datetime    method request proto status bytes}
COLTYPES = %w{to_s to_s     to_s to_datetime to_s   to_s    to_s  to_i   to_i }.map(&:to_sym)

# Reads log lines in the following format:
# host referrer user [timestamp] "GET|POST request protocol" status bytes ...
# For each parsable line, yields a Hash with the keys given by COLNAMES and the
# values parsed according to COLTYPES.
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

# Reads log entry Hashes; for each log entry with status 404, yields 
def find_404
	loop do
		r = await
		if r["status"] == 404
			yield %w{status datetime request}.map{|col| r[col].to_s}.join(" ")
		end
	end
end

def bytes_transferred
	total = 0
	loop do
		total += await["bytes"]
		yield total
	end
end

DAY = 24 * 60 * 60
def request_rate
	last = await["datetime"]
	loop do
		n = 0
		begin
			this = await["datetime"]
			n += 1
		end while this == last
		yield n.to_f / (this - last).to_f / DAY
		last = this
	end
end

def dump(label)
	loop do
		puts "#{label}: #{await}"
	end
end

def follow(path)
	file = open(path)
	loop do
		begin
			yield file.readline
		rescue EOFError
			sleep 0.1
		end
	end
	file.close
end

enum_for(:follow, "/var/log/apache2/access.log").
	out_connect(trans_for :parse).
	out_connect(Multicast.new(
		trans_for(:find_404).         out_connect(consum_for(:dump, "404        ")),
		trans_for(:bytes_transferred).out_connect(consum_for(:dump, "Total bytes")),
		trans_for(:request_rate).     out_connect(consum_for(:dump, "Requests/s "))
	)
)

