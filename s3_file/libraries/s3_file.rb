require 'time'
require 'openssl'
require 'base64'
require 'net/http'

module S3FileLib
  module SigV4
    def self.sigv4(string_to_sign, aws_secret_access_key, region, date, serviceName)
      k_date    = OpenSSL::HMAC.digest("sha256", "AWS4" + aws_secret_access_key, date)
      k_region  = OpenSSL::HMAC.digest("sha256", k_date, region)
      k_service = OpenSSL::HMAC.digest("sha256", k_region, serviceName)
      k_signing = OpenSSL::HMAC.digest("sha256", k_service, "aws4_request")

      OpenSSL::HMAC.hexdigest("sha256", k_signing, string_to_sign)
    end

    def self.sign(request, params, region, aws_access_key_id, aws_secret_access_key, token = nil)
      url = URI.parse(params[:url])
      content = request.body || ""

      algorithm = "AWS4-HMAC-SHA256"
      service = "s3"
      now = Time.now.utc
      time = now.strftime("%Y%m%dT%H%M%SZ")
      date = now.strftime("%Y%m%d")

      body_digest = Digest::SHA256.hexdigest(content)

      request["date"] = now
      request["host"] = url.host
      request["x-amz-date"] = time
      request["x-amz-security-token"] = token if token
      request["x-amz-content-sha256"] = body_digest

      canonical_query_string = url.query || ""
      canonical_headers = request.each_header.sort.map { |k, v| "#{k.downcase}:#{v.gsub(/\s+/, ' ').strip}" }.join("\n") + "\n" # needs extra newline at end
      signed_headers = request.each_name.map(&:downcase).sort.join(";")

      canonical_request = [request.method, url.path, canonical_query_string, canonical_headers, signed_headers, body_digest].join("\n")
      scope = format("%s/%s/%s/%s", date, region, service, "aws4_request")
      credential = [aws_access_key_id, scope].join("/")

      string_to_sign = "#{algorithm}\n#{time}\n#{scope}\n#{Digest::SHA256.hexdigest(canonical_request)}"
      signed_hex = sigv4(string_to_sign, aws_secret_access_key, region, date, service)
      auth_string = "#{algorithm} Credential=#{credential}, SignedHeaders=#{signed_headers}, Signature=#{signed_hex}"

      request["Authorization"] = auth_string
      request
    end
  end

  BLOCKSIZE_TO_READ = 1024 * 1000 unless const_defined?(:BLOCKSIZE_TO_READ)

  def self.detect_bucket_region(bucket)
    request = Net::HTTP::Head.new("/")
    request['Host'] = bucket
    response = Net::HTTP.start("s3.amazonaws.com", 80).request(request)

    if response["location"]
      _, _, _, s3_region = OpsWorks::SCM::S3.parse_uri(response["location"])
      Chef::Log.info("Detected bucket location is #{response["location"]}, region is #{s3_region}")
      return s3_region
    else
      Chef::Log.error("Could not determine the location from head request, response is #{response}")
      return nil
    end
  end

  def self.with_region_detect(original_url, path, bucket, region)
    Chef::Log.info("Trying to download from #{original_url} in region #{region}")
    yield(original_url, region)
  rescue client::BadRequest, client::MovedPermanently, client::TemporaryRedirect => e
    region = e.response.headers[:x_amz_region] || e.response.headers[:x_amz_bucket_region]

    # First attempt to determine region using redirection failed, trying to use head request
    if region.nil?
      Chef::Log.warn("Could not download from S3: #{e.message}, trying to determine bucket region using head request")
      region = detect_bucket_region(bucket)

      # Second attempt to determine region using head request failed, exiting the process
      if region.nil?
        Chef::Log.error("Could not determine the region of S3 bucket #{bucket}, please verify the S3 URL #{original_url}")
        raise
      end
    end

    Chef::Log.warn("First download try failed with '#{e.message}' (#{e.class}), retrying")

    url = [build_endpoint_url(bucket, region), path].join()
    Chef::Log.info("Retrying S3 download with new url #{url} in region #{region}")
    yield(url, region)
  end

  def self.do_request(method, url, bucket, path, aws_access_key_id, aws_secret_access_key, token, region)
    url = build_endpoint_url(bucket, region) if url.nil?
    url = "#{url}#{path}"

    # do not sign requests for public endpoints 
    #
    client.reset_before_execution_procs
    return client::Request::execute(:method => method, :url => url, :raw_response => true) if is_public_s3_endpoint?(url)

    with_region_detect(url, path, bucket, region) do |real_url, real_region|
      client.reset_before_execution_procs
      client.add_before_execution_proc do |request, params|
        SigV4.sign(request, params, real_region, aws_access_key_id, aws_secret_access_key, token)
      end
      client::Request.execute(:method => method, :url => real_url, :raw_response => true)
    end
  end

  def self.build_endpoint_url(bucket, region)
    if region == "us-east-1"
      # Virtual Hosting style url is not supported in us-east-1
      # https://docs.aws.amazon.com/AmazonS3/latest/dev/VirtualHosting.html
      "https://s3.amazonaws.com/#{bucket}"
    else
      "https://s3-#{region}.amazonaws.com/#{bucket}"
    end
  end

  def self.get_md5_from_s3(bucket, url, path, aws_access_key_id, aws_secret_access_key, token, region)
    get_digests_from_s3(bucket, url, path, aws_access_key_id, aws_secret_access_key, token, region)["md5"]
  end

  def self.get_digests_from_s3(bucket,url,path,aws_access_key_id,aws_secret_access_key,token, region)
    response = do_request("HEAD", url, bucket, path, aws_access_key_id, aws_secret_access_key, token, region)

    etag = response.headers[:etag].gsub('"','')
    digest = response.headers[:x_amz_meta_digest]
    digests = digest.nil? ? {} : Hash[digest.split(",").map {|a| a.split("=")}]

    return {"md5" => etag}.merge(digests)
  end

  def self.get_from_s3(bucket, url, path, aws_access_key_id, aws_secret_access_key, token, region)
    response = nil
    retries = 5
    for attempts in 0..retries
      begin
        response = do_request("GET", url, bucket, path, aws_access_key_id, aws_secret_access_key, token, region)
        return response
        # break
      rescue client::MovedPermanently, client::Found, client::TemporaryRedirect => e
        uri = URI.parse(e.response.header['location'])
        path = uri.path
        uri.path = ""
        url = uri.to_s
        retry
      rescue => e
        error = e.respond_to?(:response) ? e.response : e
        if attempts < retries
          Chef::Log.warn(error)
          sleep 5
          next
        else
          Chef::Log.fatal(error)
          raise e
        end
        raise e
      end
    end
  end

  def self.aes256_decrypt(key, file)
    Chef::Log.debug("Decrypting S3 file.")
    key = key.strip
    require "digest"
    key = Digest::SHA256.digest(key) if(key.kind_of?(String) && 32 != key.bytesize)
    aes = OpenSSL::Cipher.new('AES-256-CBC')
    aes.decrypt
    aes.key = key
    decrypt_file = Tempfile.new("chef-s3-decrypt")
    File.open(decrypt_file, "wb") do |df|
      File.open(file, "rb") do |fi|
        while buffer = fi.read(BLOCKSIZE_TO_READ)
          df.write aes.update(buffer)
        end
      end
      df.write aes.final
    end
    decrypt_file
  end

  def self.verify_sha256_checksum(checksum, file)
    recipe_sha256 = checksum
    local_sha256 = Digest::SHA256.new

    File.open(file, "rb") do |fi|
      while buffer = fi.read(BLOCKSIZE_TO_READ)
        local_sha256.update buffer
      end
    end

    Chef::Log.debug "sha256 provided #{recipe_sha256}"
    Chef::Log.debug "sha256 of local object is #{local_sha256.hexdigest}"

    local_sha256.hexdigest == recipe_sha256
  end

  def self.verify_md5_checksum(checksum, file)
    s3_md5 = checksum
    local_md5 = Digest::MD5.new

    # buffer the checksum which should save RAM consumption
    File.open(file, "rb") do |fi|
      while buffer = fi.read(BLOCKSIZE_TO_READ)
        local_md5.update buffer
      end
    end

    Chef::Log.debug "md5 of remote object is #{s3_md5}"
    Chef::Log.debug "md5 of local object is #{local_md5.hexdigest}"

    local_md5.hexdigest == s3_md5
  end

  def self.is_public_s3_endpoint?(url)
    resp = client::Request.execute(:method => "HEAD", :url => url, :raw_response => true)
    resp.code == 200
  rescue => e
    Chef::Log.info("Assuming S3 endpoint is not public (#{e.message})")
    return false
  end

  def self.client
    require 'rest-client'
    RestClient.proxy = ENV['http_proxy']
    RestClient.proxy = ENV['https_proxy']
    RestClient.proxy = ENV['no_proxy']
    RestClient
  end
end
