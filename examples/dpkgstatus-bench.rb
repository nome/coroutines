require 'coroutines'
require 'benchmark'

$sink = open("/dev/null", "w")

# Transformer that accepts lines of text and 
# * appends any lines starting with a space to the previous line
# * parses each set of non-empty concatenated lines as a key:value pair and
#   yields that pair as an Array
def parse_dpkg_status
	line = await
	loop do
		accum = ""
		begin
			begin
				accum += line
				line = await
			end while line.start_with? " "
		ensure
			key, value = accum.split(":", 2)
			yield [key.strip, value.strip] if accum != "\n"
		end
	end
end

# prime caches
open("/var/lib/dpkg/status").read

Benchmark.bm(10) do |test|
	test.report("imperative") do
		open("/var/lib/dpkg/status").each("\n\n") do |p|
			rec = Hash.new
			for field in p.split(/\n(?! )/)
				key, value = field.split(":", 2)
				rec[key] = value
			end
			$sink.write "#{rec["Package"]} #{rec["Version"]}\n"
		end
	end

	if defined? Enumerator::Lazy
		# require Ruby >= 2.0
		test.report("enumerator") do
			paragraphs = open("/var/lib/dpkg/status").each("\n\n").lazy
			records = paragraphs.map do |p|
				p.split(/\n(?! )/).map{ |field| field.split(":", 2) }
			end.map{|assocs| Hash[assocs]}
			records.each { |rec| $sink.write "#{rec["Package"]} #{rec["Version"]}\n" }
		end
	end

	test.report("consumer") do
		record_dumper = $sink.dup.input_map{ |rec| "#{rec["Package"]} #{rec["Version"]}\n" }
		paragraph_handler = record_dumper.input_map do |l|
			{}.input_map{ |field| field.split(":", 2) } <= l
		end.input_map{ |p| p.split(/\n(?! )/) }
		open("/var/lib/dpkg/status").each("\n\n") >= paragraph_handler
	end

	test.report("transformer") do
		open("/var/lib/dpkg/status").each("\n\n").map do |p|
			p.each_line >= trans_for(:parse_dpkg_status) >= {}
		end.each do |rec|
			$sink.write "#{rec["Package"]} #{rec["Version"]}\n"
		end
	end

	test.report("pipeline") do
		open("/var/lib/dpkg/status").each("\n\n")                       >= \
			proc{|p| p.split(/\n(?! )/).map{|f| f.split(":", 2)} >= {} }  >= \
			proc{|rec| "#{rec["Package"]} #{rec["Version"]}\n" }          >= \
			$sink.dup
	end
end
