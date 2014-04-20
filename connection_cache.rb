module Blitline
	class ConnectionCache
		def initialize(config)
			aws_access_key_id = config[:aws_access_key]
			aws_secret_access_key = config[:aws_access_secret]
			raise "Invalid config in ConnectionCache" unless aws_access_key_id && aws_secret_access_key
			@s3 = RightAws::S3Interface.new(aws_access_key_id, aws_secret_access_key)

	        location = "ap-southeast-1"
	        server = "s3-#{location}.amazonaws.com"
	        @s3_ap_southeast_1 = RightAws::S3Interface.new(aws_access_key_id, aws_secret_access_key, { :server => server})

	        location = "ap-northeast-1"
	        server = "s3-#{location}.amazonaws.com"
	        @s3_ap_northeast_1 = RightAws::S3Interface.new(aws_access_key_id, aws_secret_access_key, { :server => server})

	        location = "ap-southeast-2"
	        server = "s3-#{location}.amazonaws.com"
	        @s3_ap_southeast_2 = RightAws::S3Interface.new(aws_access_key_id, aws_secret_access_key, { :server => server})

	        location = "sa-east-1"
	        server = "s3-#{location}.amazonaws.com"
	        @s3_sa_east_1 = RightAws::S3Interface.new(aws_access_key_id, aws_secret_access_key, { :server => server})

	        location = "us-west-2"
	        server = "s3-#{location}.amazonaws.com"
	        @s3_us_west_2 = RightAws::S3Interface.new(aws_access_key_id, aws_secret_access_key, { :server => server})

	        location = "us-west-1"
	        server = "s3-#{location}.amazonaws.com"
	        @s3_us_west_1 = RightAws::S3Interface.new(aws_access_key_id, aws_secret_access_key, { :server => server})

	        location = "eu-west-1"
	        server = "s3-#{location}.amazonaws.com"
	        @s3_eu_west_1 = RightAws::S3Interface.new(aws_access_key_id, aws_secret_access_key, { :server => server})
		end

		def get_s3_connection(location = nil)
			return @s3 unless location

			case location
				when "ap-southeast-1"
					return @s3_ap_southeast_1
				when "ap-southeast-2"
					return @s3_ap_southeast_2
				when "ap-northeast-1"
					return @s3_ap_northeast_1
				when "sa-east-1"
					return @s3_sa_east_1
				when "us-west-2"
					return @s3_us_west_2
				when "us-west-1"
					return @s3_us_west_1
				when "eu-west-1"
					return @s3_eu_west_1
			end
			return @s3
		end

	end
end