require 'net/http'
require 'net/https'
require 'uri'
require 'open-uri'
require 'open3'
require 'fileutils'
require 'httparty'
unless defined?(Blitline::Utils)
  require 'blitline/job/utils'
end

module Blitline
  attr_reader :http
  VALID_EXTENSIONS = ["ai", "bmp", "bmp2", "bmp3", "epi", "eps", "gif", "gif87", "ico", "icon", "jng", "jpeg",
  "jpg", "mpeg", "mpg", "pal", "pcd", "pcl", "pct", "pcx", "pdf", "pdfa", "pix", "pjpeg",
  "png", "png8", "psd", "ptif", "svg", "svgz", "tif", "tiff", "tiff64", "wpg", "xps", "icc", "icm", "webp"]

  # Blitline HTTP Client
  # Simplify API for making HTTP requests. Handle HTTPS in a consistent manner.
  class HttpClient
    # Creates an HTTP client from the specified host and port
    # options:
    #   :use_ssl => whether to use SSL
    #   :ca_file => certificate authority file
    #   :open_timeout => timeout in secs for connection to be established
    #   :read_timeout => timeout in secs for reading data
    def initialize(host, port, options={})
      @http = Net::HTTP.new(host, port)
      if options.key?(:use_ssl) ? options[:use_ssl] : port == 443
        @http.use_ssl = true
        @http.verify_mode = OpenSSL::SSL::VERIFY_NONE
        @http.ca_file = options[:ca_file]
      end

      @http.open_timeout = 10
      @http.read_timeout = 20
    end

    # expose the underlying Net::HTTP object
    attr_reader :http

    # Perform a GET request. Auto-follows redirects until redirect_limit reached.
    # Optionally takes a block to receive chunks of the response.
    # Raises Net::HTTPExceptions if response code not 2xx.
    def get(path, redirect_limit=5, &block)
      request = Net::HTTP::Get.new(path)
      @http.request(request) do |response|
        if response.is_a? Net::HTTPSuccess
          return response.read_body(&block)
        elsif response.is_a? Net::HTTPRedirection
          return follow_redirect(response, redirect_limit, &block)
        else
          response.read_body
          response.error!
        end
      end
    end

    # Perform a POST request.
    # Optionally takes a form_data hash.
    # Optionally takes a block to receive chunks of the response.
    # Raises Net::HTTPExceptions if response code not 2xx.
    def post(path, form_data=nil, &block)
      request = Net::HTTP::Post.new(path)
      request.set_form_data(form_data) if form_data
      @http.request(request) do |response|
        if response.is_a? Net::HTTPSuccess
          return response.read_body(&block)
        else
          response.read_body
          response.error!
        end
      end
    end

    # Perform a DELETE request.
    # Optionally takes a block to receive chunks of the response.
    # Raises Net::HTTPExceptions if response code not 2xx.
    def delete(path, &block)
      request = Net::HTTP::Delete.new(path)
      @http.request(request) do |response|
        if response.is_a? Net::HTTPSuccess
          return response.read_body(&block)
        else
          response.error!
        end
      end
    end

    def self.url_available?(uri)
      response = HTTParty.get(uri.to_s)
      if response.code.to_s != "200"
        puts response.code.inspect
        puts response.inspect
      end
      return response.code.to_s == "200"

      rescue
        return false
    end

    def self.exists?(uri)
      uri = URI.parse(uri) unless uri.is_a?(URI)

      Net::HTTP.start(uri.host) do |http|
        http.open_timeout = 2
        http.read_timeout = 2
        path = uri.path
        path = path + "/#{uri.query}" if uri.query
        return http.head(path).code == "200" ? true : false
      end

      rescue
        return false
    end

    def self.derive_file_extension(filepath)
      extension = File.extname(filepath.to_s).split("?")[0].to_s.downcase
      if VALID_EXTENSIONS.include?(extension.gsub(".",""))
        return extension
      end
      return ""
    end

    # Creates a new HttpClient based on the specified uri.
    def self.from_uri(uri, options={})
      uri = URI.parse(uri) unless uri.is_a?(URI)
      raise ArgumentError, 'uri should be HTTP' unless uri.is_a?(URI::HTTP)
      new(uri.host, uri.port, options.merge(:use_ssl => uri.is_a?(URI::HTTPS)))
    end

    # Creates a new HttpClient and performs a GET based on the specified uri.
    def self.get(uri, redirect_limit=5, options={}, &block)
      uri = URI.parse(uri) unless uri.is_a?(URI)
      from_uri(uri, options).get(uri.request_uri, redirect_limit, &block)
    end

    def self.download_file(source_url, dest_path = nil)
      file_extension = Blitline::HttpClient.derive_file_extension(source_url)
      if dest_path.nil?
        dest_path = File.join(Dir.tmpdir, Blitline::Utils.suid + "#{file_extension}")
      end

      if file_extension != Blitline::HttpClient.derive_file_extension(dest_path)
        dest_path = dest_path.to_s + file_extension
      end
      source_url = source_url.to_s.gsub("'","%27")
      execution_string = "wget -U 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_6_8) AppleWebKit/537.17 (KHTML, like Gecko) Chrome/24.0.1312.52 Safari/537.17' --no-check-certificate -nv --timeout=60 -t 2 -O '#{dest_path}' '#{source_url}'"
      puts "WGET #{execution_string}"
      success = system(execution_string)
      if !File.exists?(dest_path) || success.to_s!="true"
        stdin, stdout, stderr = Open3.popen3(execution_string)
        FileUtils.rm dest_path if File.exists? dest_path
        BlitlineLogger.log "STDOUT...   #{stdout.read}"
        BlitlineLogger.log "STDERR...   #{stderr.read}"
        error_message = $?
        error_text = "Sorry, as hard as I tried...and retried...I could not download that file. "
        if error_message.to_s.include?("exit 8")
          error_text = "Server issued 5xx or 4xx response, so we bailed. If you are reading from S3 it is probably a permission problem."
        elsif error_message.to_s.include?("exit 5")
          error_text = "Server issued an unsupported SSL verification."
        elsif error_message.to_s.include?("exit 4")
          error_text = "Generic network error (exit 4). For some reason we cannot download that file"
        elsif error_message.to_s.include?("Scheme missing")
          error_text = "Looks like there is no 'http' starting the src. You must download from an http address."
        end

        raise "Failed to download file from #{source_url}. #{error_text}"
      end

      return dest_path.to_s
    end

    # Creates a new HttpClient and performs a POST based on the specified uri.
    def self.post_as_json(uri, form_data=nil, options={}, &block)
        uri = URI.parse(uri) unless uri.is_a?(URI)
        use_ssl = uri.is_a?(URI::HTTPS)
        @host = uri.host
        @port = uri.port
        @post_ws = uri.path
        @payload = Yajl::Encoder.encode(form_data)
        req = Net::HTTP::Post.new(uri.to_s, initheader = {'Content-Type' =>'application/json'})
        if options[:username] && options[:password]
          req.basic_auth options[:username], options[:password]
        end

        if options[:headers]
          options[:headers].each do |key, value|
            req[key] = value
          end
        end

        net_http = Net::HTTP.new(@host, @port)
        if use_ssl
            puts "Using SSL"
            net_http.use_ssl = true
            net_http.verify_mode = OpenSSL::SSL::VERIFY_NONE
        end
        
#        if @host && @host.include?("diybooths.sg")
 #         BlitlineLogger.log("Setting set_debug_output")
  #        net_http.set_debug_output $stdout
   #     end

        req.body = @payload
        response = net_http.start {|http| http.request(req) }
    end

    # Creates a new HttpClient and performs a POST based on the specified uri.
    def self.post(uri, form_data=nil, options={}, &block)
      uri = URI.parse(uri) unless uri.is_a?(URI)
      from_uri(uri, options).post(uri.request_uri, form_data, &block)
    end

    # Creates a new HttpClient and performs a DELETE based on the specified uri.
    def self.delete(uri, options={}, &block)
      uri = URI.parse(uri) unless uri.is_a?(URI)
      from_uri(uri, options).delete(uri.request_uri, &block)
    end

    private
      def follow_redirect(response, redirect_limit, &block)
        response.error! unless redirect_limit > 0
        redirect_limit -= 1

        location = URI.parse(response['location'])

        # if location is relative then use self as http client
        return get(location.to_s, redirect_limit, &block) if location.relative?

        # only follow http locations
        response.error! unless location.is_a?(URI::HTTP)

        # build http_client from location and get location
        options = {
          :open_timeout => @http.open_timeout,
          :read_timeout => @http.read_timeout,
          :ca_file => @http.ca_file
        }
        return self.class.get(location, redirect_limit, options, &block)
      end
  end
end
