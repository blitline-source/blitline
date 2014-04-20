module Rightscale
	class HttpConnection
		def self.get_http_params
			return @@params
		end

	  	def self.set_http_params(options)
			@@params.merge!(options)
	    end
	end
end

# This patch is to allow us to set default http connection info that is
# different between SDB and S3 connections.
Rightscale::HttpConnection.set_http_params({
	:http_connection_retry_count => 4,
	:http_connection_open_timeout => 10,
	:http_connection_read_timeout => 15
})

puts "\033[32mBlitline setting Default Rightscale HttpConnection Values #{Rightscale::HttpConnection.get_http_params.inspect}\033[0m"