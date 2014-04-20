require 'tempfile'
require 'waz-blobs'
require 'httparty'
require 'RMagick'
require 'blitline/job/utils'
require 'net/ftp'
require 'oj'

module Azure
    include HTTParty

    def self.push_to_azure(account_name, additional_headers, shared_access_signature, file_path)
        additional_headers = {} if additional_headers.nil?
        base_uri = "#{account_name}.blob.core.windows.net"
        headers = {
          "x-ms-Date" => "Thu, 12 Apr 2013 01:14:57 GMT",
          "x-ms-blob-type" => "BlockBlob"
        }.merge(additional_headers)
        string = File.open(file_path, 'rb') { |file| file.read }
        res = put(shared_access_signature, {:body => string, :headers => headers})
        return res
    end
end

module Blitline
    class Uploader
        BL_TEMP_BUCKET = "bltemp.shortlife"

        def initialize(connection_cache)
            @connection_cache = connection_cache
        end

        def self.append_index_to_filepath(filepath, index)
            path = File.dirname(filepath)
            name = File.basename(filepath, File.extname(filepath))
            ext = File.extname(filepath)

            return "#{path}/#{name}_#{index.to_s}#{ext}"
        end

        def download_from_s3(key, bucket)
            BlitlineLogger.log("Download from s3 #{bucket.inspect}/#{key.inspect}")
            location = nil
            temp_filepath = ""
            ext = File.extname(key)

            f = Tempfile.open('blitline')
            begin
                temp_filepath = f.path
            ensure
                f.close!
            end

            file_path = temp_filepath
            if ext && ext.length > 0
                file_path = file_path + ext
            end
            BlitlineLogger.log(file_path)

            s3 = @connection_cache.get_s3_connection
            if bucket.is_a?(Hash)
                location = bucket['location']
                bucket = bucket['name']
                s3 = @connection_cache.get_s3_connection(location)
            end

            begin
                open(file_path, 'wb') do |file|
                    s3.get(bucket, key) do |chunk|
                        file.write(chunk)
                    end
                end
            rescue => ex
                BlitlineLogger.log(ex)
                begin
                    s3.head(bucket, key)
                rescue => permex
                    BlitlineLogger.log(permex)
                    raise "Failed to download from s3 (#{permex.message})"
                end

                raise "Failed to download from source S3 location"
            end
            return file_path
        end

        def upload_to_s3_from_image(image, bucket, key)
            url = nil

            file_extension = Blitline::HttpClient.derive_file_extension(key)
            file_extension = ".png" if file_extension.nil? || file_extension.length==0
            headers = derive_headers(image.filename, nil, nil, nil, nil)
            download_file_directory = Dir.tmpdir
            tmp_file = File.join(download_file_directory,  Blitline::Utils.suid + file_extension)
            begin
                image.write(tmp_file)
                url = upload_to_s3(tmp_file, bucket, key, headers, nil)
            ensure
                FileUtils.rm tmp_file if !tmp_file.nil? && File.exists?(tmp_file)
            end
            return url

        end


        def upload_json_to_s3(suid, json, destination)
            download_file_directory = Dir.tmpdir
            file = File.join(download_file_directory,  suid + ".json")

            File.open(file,"w") do |f|
                f.write(Oj.dump(json))
            end
            begin
                if (destination["s3_destination"])
                    headers = destination["s3_destination"]["headers"]
                    bucket = destination["s3_destination"]["bucket"]
                    key = destination["s3_destination"]["key"]
                    if bucket.is_a?(Hash)
                        location = bucket['location']
                        bucket = bucket['name']
                    end
                    s3_put_headers = { "content-type" => "application/json"}
                    s3_put_headers["x-amz-acl"] = "bucket-owner-full-control"
                    s3_put_headers.merge!(headers) if headers

                    if location
                        # Non US Bucket, so we have to do a little dance
                        s3 = @connection_cache.get_s3_connection(location)
                    else
                        # Standard US bucket, no problems...
                        s3 = @connection_cache.get_s3_connection
                    end
                    s3.put(bucket, key, Oj.dump(json), s3_put_headers)
                elsif (destination["azure_destination"])
                    shared_access_signature = destination["azure_destination"]["shared_access_signature"]
                    account_name = destination["azure_destination"]["account_name"]
                    headers = destination["azure_destination"]["headers"]
                    uri = URI.parse(shared_access_signature)
                    url = "#{uri.scheme}://#{uri.host}#{uri.path}"

                    response = Azure.push_to_azure(account_name, headers, shared_access_signature, file)
                    unless response.response.is_a?(::Net::HTTPCreated)
                        BlitlineLogger.log response.inspect
                        begin
                            if response.response && response.response.body
                                BlitlineLogger.log("Body-->" + response.response.body.inspect)
                                raise "Failed to upload to azure: #{response.response.body}" 
                            end
                        rescue => subex
                            BlitlineLogger.log(ex)
                        end

                        raise "Failed to upload to azure #{response.inspect}" 
                    end
                end
            ensure
                FileUtils.rm file if !file.nil? && File.exists?(file)
            end
        end

    	def upload_to_ftp(filepath, target_server, target_path, target_name, username, password)
    	    begin
    	        ftp = Net::FTP.new(target_server, username, password)
    	     	ftp.chdir(target_path) 
                    file = File.new(filepath)
    	    	ftp.putbinaryfile(file, target_name)
                	ftp.quit()
                    sleep(0.01) # A little throttling to ensure performance
    	    rescue => ex
    	        BlitlineLogger.log("FTP UPLOAD FAIL #{ex.message}")
                    BlitlineLogger.log(ex)
                    return { :error => ex.message }            	
                end
                return "ftp://#{target_server}/#{target_path}/#{target_name}"
    	end

        def simple_upload_to_s3(file_path)
            file_extension = File.extname(file_path)
            bucket = BL_TEMP_BUCKET
            key = "#{Blitline::Utils.suid}/#{Blitline::Utils.suid}#{file_extension}"
            url = upload_to_s3(file_path, bucket, key, nil, nil, nil)
            wait_for_s3([url])
            return url
        end

        def wait_for_s3(s3_urls)
            1.upto(20) do
                all_exist = true
                s3_urls.each do |url|
                    unless Blitline::HttpClient.exists?(url)
                        all_exist = false
                        BlitlineLogger.log "...waiting"
                        break;
                    end
                end
                return if all_exist
                sleep 0.2
            end
        end

        def upload_to_s3(file_path, bucket, key, headers, canonical_id, public_token = nil)
            location = nil

            if bucket.is_a?(Hash)
                location = bucket['location']
                bucket = bucket['name']
            end
            server = ""
            sleep(0.01) # For big multi writes this will help throttle S3 pushes

            open(file_path, 'rb') do |file|
                if location
                    # Non US Bucket, so we have to do a little dance
                    BlitlineLogger.log("Uploading to NON-US location:" + location)
                    s3 = @connection_cache.get_s3_connection(location)
                    s3_put_headers = derive_headers(file_path, location, headers, canonical_id, public_token)
                    BlitlineLogger.log("Headers" + s3_put_headers.inspect)
                    server = "s3-#{location}.amazonaws.com"
                else
                    # Standard US bucket, no problems...
                    s3 = @connection_cache.get_s3_connection
                    s3_put_headers = derive_headers(file_path, location, headers, canonical_id, public_token)
                    BlitlineLogger.log("Headers" + s3_put_headers.inspect)
                end
                s3.put(bucket, key, file, s3_put_headers)
                BlitlineLogger.log("Put OK")
            end

            if location
                # Non US Bucket
                destination = "http://" + server + "/" + bucket + "/" + key
            else
                # Standard US Bucket
                destination = "http://s3.amazonaws.com/"+ bucket + "/" + key
            end

            return destination
        rescue => ex
            BlitlineLogger.log("S3 UPLOAD FAIL #{ex.message}")
            BlitlineLogger.log(ex)
            return { :error => ex.message }
        end

        def upload_to_azure(account_name, shared_access_signature, file_path, headers = {})
            retry_count = 0
            begin
                headers = {} if headers.nil?
                unless file_path.nil? || file_path.empty?
                    ext = File.extname(file_path)
                    if (ext.downcase==".jpg")
                        headers['content-type'] = "image/jpeg" unless headers['content-type']
                        headers['x-ms-blob-content-type'] = "image/jpeg" unless headers['x-ms-blob-content-type']
                    elsif (ext.downcase==".png")
                        headers['content-type'] = "image/png" unless headers['content-type']
                        headers['x-ms-blob-content-type'] = "image/jpeg" unless headers['x-ms-blob-content-type']
                    end
                end
                uri = URI.parse(shared_access_signature)
                url = "#{uri.scheme}://#{uri.host}#{uri.path}"

                response = Azure.push_to_azure(account_name, headers, shared_access_signature, file_path)
                unless response.response.is_a?(::Net::HTTPCreated)
                    BlitlineLogger.log response.inspect
                    begin
                        if response.response && response.response.body
                            BlitlineLogger.log("Body-->" + response.response.body.inspect) 
                            raise "Failed to upload to azure: #{response.response.body}" 

                        end
                    rescue => subex
                        BlitlineLogger.log(ex)
                    end

                    raise "Failed to upload to azure #{response.inspect}" 
                end
                return url
            rescue => ex
              #  retry_count = retry_count + 1
               # sleep(1)
                #retry if retry_count < 3
                BlitlineLogger.log(ex)
                if response && response.response
                    BlitlineLogger.log(response.response.inspect)
                end
                return { :error => ex.message }
            end
        end


        def derive_headers(file_path, location, other_headers, canonical_id, public_token)

#            other_headers.delete("x-amz-meta-ptoken") if other_headers
            if canonical_id && canonical_id.length > 0
                if canonical_id.include?("@")
                    result = {
                        "x-amz-grant-read" => "uri=http://acs.amazonaws.com/groups/global/AllUsers",
                        "x-amz-grant-full-control" => "emailAddress=#{canonical_id}"
                    }
                else
                    result = {
                        "x-amz-grant-read" => "uri=http://acs.amazonaws.com/groups/global/AllUsers",
                        "x-amz-grant-full-control" => "id=#{canonical_id}"
                    }
                end
            else
                result = {'x-amz-acl'=>'public-read'}
            end

            unless file_path.nil? || file_path.empty?
                ext = File.extname(file_path)
                if (ext.downcase==".jpg")
                    result['content-type'] = "image/jpeg"
                elsif (ext.downcase==".png")
                    result['content-type'] = "image/png"
                elsif (ext.downcase==".zip")
                    result['content-type'] = "application/zip"
                end
            end
            result["location"] = location if location # Location refers to foreign(EU) s3 buckets
            begin
                if other_headers
                    other_header_hash = other_headers
                    result.merge!(other_headers)
                    result = result.delete_if { |k, v| v.nil? || v.to_s == "" }
                end
            rescue Exception => ex
                BlitlineLogger.log(ex)
            end

 #           result["x-amz-meta-ptoken"] = public_token
            return result
        end

    end
end
