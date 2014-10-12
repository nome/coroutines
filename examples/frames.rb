require 'coroutines'

# Example shamelessly stolen from
# http://eli.thegreenplace.net/2009/08/29/co-routines-as-an-alternative-to-state-machines/

def unwrap(header=0x61, footer=0x62, escape=0xAB)
	loop do
		byte = await
		next if byte != header

		frame = ""
		loop do
			byte = await
			case byte
			when footer
				yield frame
				break
			when escape
				frame += await.to_s(16)
			else
				frame += byte.to_s(16)
			end
		end
	end
end

data = "\x70\x24\x61\x99\xAF\xD1xyzz\x62\x56\x62\x61\xAB\xAB\x14\x62\x07"

data.each_byte.out_connect(trans_for :unwrap).out_connect(method(:puts))

