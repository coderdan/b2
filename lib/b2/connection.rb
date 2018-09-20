class B2
  class Connection
    
    attr_reader :account_id, :application_key, :download_url
    
    def initialize(account_id, application_key)
      @account_id = account_id
      @application_key = application_key
    end
    
    def connect!
      conn = Net::HTTP.new('api.backblazeb2.com', 443)
      conn.use_ssl = true
      
      req = Net::HTTP::Get.new('/b2api/v1/b2_authorize_account')
      req.basic_auth(account_id, application_key)

      key_expiration = Time.now.to_i + 86_400 #24hr expiry
      resp = conn.start { |http| http.request(req) }
      if resp.is_a?(Net::HTTPSuccess)
        resp = JSON.parse(resp.body)
      else
        raise "Error connecting to B2 API"
      end

      uri = URI.parse(resp['apiUrl'])
      @connection = Net::HTTP.new(uri.host, uri.port)
      @connection.use_ssl = uri.scheme == 'https'
      @connection.start

      @auth_token_expires_at = key_expiration
      @minimum_part_size = resp['absoluteMinimumPartSize']
      @recommended_part_size = resp['recommendedPartSize']
      @auth_token = resp['authorizationToken']
      @download_url = resp['downloadUrl']
    end
    
    def disconnect!
      if @connection
        @connection.finish if @connection.active?
        @connection = nil
      end
    end
    
    def reconnect!
      disconnect!
      connect!
    end
    
    def authorization_token
      if @auth_token_expires_at.nil? || @auth_token_expires_at <= Time.now.to_i
        reconnect!
      end
      @auth_token
    end
    
    def active?
      !@connection.nil? && @connection.active?
    end

    def send_request(request, body=nil, &block)
      request['Authorization'] = authorization_token
      request.body = (body.is_a?(String) ? body : JSON.generate(body)) if body
      
      return_value = nil
      close_connection = false
      @connection.request(request) do |response|
        close_connection = response['Connection'] == 'close'
        
        case response
        when Net::HTTPSuccess
          if block_given?
            return_value = yield(response)
          else
            return_value = JSON.parse(response.body)
          end
        else
          raise "Error connecting to B2 API #{response.body}"
        end
      end
      @connection.finish if close_connection

      return_value
    end
    
    def download(bucket, key, to=nil, &block)
      opened_file = (to && to.is_a?(String))
      to = ::File.open(to, 'wb') if to.is_a?(String)
      digestor = Digest::SHA1.new
      data = ""
    
      uri = URI.parse(@download_url)
      conn = Net::HTTP.new(uri.host, uri.port)
      conn.use_ssl = uri.scheme == 'https'

      req = Net::HTTP::Get.new("/file/#{bucket}/#{key}")
      req['Authorization'] = authorization_token
      conn.start do |http|
        http.request(req) do |response|
          case response
          when Net::HTTPSuccess
            response.read_body do |chunk|
              digestor << chunk
              if to
                to << chunk
              elsif block
                block(chunk)
              else
                data << chunk
              end
            end
      
            if digestor.hexdigest != response['X-Bz-Content-Sha1']
              raise 'file error'
            end
          else
            raise response.body
          end
        end
      end
      
      if opened_file
        to.close
      elsif to
        to.flush
      end
      block.nil? && to.nil? ? data : nil
    end
    
    def get(path, body=nil, &block)
      request = Net::HTTP::Get.new(path)
      
      send_request(request, body, &block)
    end
    
    def post(path, body=nil, &block)
      request = Net::HTTP::Post.new(path)
      
      send_request(request, body, &block)
    end
    
  end
end