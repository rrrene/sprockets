require 'time'
require 'rack/utils'

module Sprockets
  # `Server` is a concern mixed into `Environment` and
  # `CachedEnvironment` that provides a Rack compatible `call`
  # interface and url generation helpers.
  module Server
    # `call` implements the Rack 1.x specification which accepts an
    # `env` Hash and returns a three item tuple with the status code,
    # headers, and body.
    #
    # Mapping your environment at a url prefix will serve all assets
    # in the path.
    #
    #     map "/assets" do
    #       run Sprockets::Environment.new
    #     end
    #
    # A request for `"/assets/foo/bar.js"` will search your
    # environment for `"foo/bar.js"`.
    def call(env)
      start_time = Time.now.to_f
      time_elapsed = lambda { ((Time.now.to_f - start_time) * 1000).to_i }

      msg = "Served asset #{env['PATH_INFO']} -"

      # Extract the path from everything after the leading slash
      path = Rack::Utils.unescape(env['PATH_INFO'].to_s.sub(/^\//, ''))

      # URLs containing a `".."` are rejected for security reasons.
      if forbidden_request?(path)
        return forbidden_response
      end

      # Strip fingerprint
      if fingerprint = path_fingerprint(path)
        path = path.sub("-#{fingerprint}", '')
      end

      # Look up the asset.
      options = {}
      options[:bundle] = !body_only?(env)

      if fingerprint
        options[:if_match] = fingerprint
      elsif env['HTTP_ACCEPT_ENCODING']
        # Accept-Encoding negotiation is only enabled for non-fingerprinted
        # assets. Avoids the "Apache ETag gzip" bug. Just Google it.
        # https://issues.apache.org/bugzilla/show_bug.cgi?id=39727
        options[:accept_encoding] = env['HTTP_ACCEPT_ENCODING']
      end

      asset = find_asset(path, options)

      # `find_asset` returns nil if the asset doesn't exist
      if asset.nil?
        logger.info "#{msg} 404 Not Found (#{time_elapsed.call}ms)"

        # Return a 404 Not Found
        not_found_response

      # Check request headers `HTTP_IF_NONE_MATCH` against the asset digest
      elsif etag_match?(asset, env)
        logger.info "#{msg} 304 Not Modified (#{time_elapsed.call}ms)"

        # Return a 304 Not Modified
        not_modified_response(asset, env)

      else
        logger.info "#{msg} 200 OK (#{time_elapsed.call}ms)"

        # Return a 200 with the asset contents
        ok_response(asset, env)
      end
    rescue Exception => e
      logger.error "Error compiling asset #{path}:"
      logger.error "#{e.class.name}: #{e.message}"

      case File.extname(path)
      when ".js"
        # Re-throw JavaScript asset exceptions to the browser
        logger.info "#{msg} 500 Internal Server Error\n\n"
        return javascript_exception_response(e)
      when ".css"
        # Display CSS asset exceptions in the browser
        logger.info "#{msg} 500 Internal Server Error\n\n"
        return css_exception_response(e)
      else
        raise
      end
    end

    private
      def forbidden_request?(path)
        # Prevent access to files elsewhere on the file system
        #
        #     http://example.org/assets/../../../etc/passwd
        #
        path.include?("..")
      end

      # Returns a 403 Forbidden response tuple
      def forbidden_response
        [ 403, { "Content-Type" => "text/plain", "Content-Length" => "9" }, [ "Forbidden" ] ]
      end

      # Returns a 404 Not Found response tuple
      def not_found_response
        [ 404, { "Content-Type" => "text/plain", "Content-Length" => "9", "X-Cascade" => "pass" }, [ "Not found" ] ]
      end

      # Returns a JavaScript response that re-throws a Ruby exception
      # in the browser
      def javascript_exception_response(exception)
        err  = "#{exception.class.name}: #{exception.message}\n  (in #{exception.backtrace[0]})"
        body = "throw Error(#{err.inspect})"
        [ 200, { "Content-Type" => "application/javascript", "Content-Length" => body.bytesize.to_s }, [ body ] ]
      end

      # Returns a CSS response that hides all elements on the page and
      # displays the exception
      def css_exception_response(exception)
        message   = "\n#{exception.class.name}: #{exception.message}"
        backtrace = "\n  #{exception.backtrace.first}"

        body = <<-CSS
          html {
            padding: 18px 36px;
          }

          head {
            display: block;
          }

          body {
            margin: 0;
            padding: 0;
          }

          body > * {
            display: none !important;
          }

          head:after, body:before, body:after {
            display: block !important;
          }

          head:after {
            font-family: sans-serif;
            font-size: large;
            font-weight: bold;
            content: "Error compiling CSS asset";
          }

          body:before, body:after {
            font-family: monospace;
            white-space: pre-wrap;
          }

          body:before {
            font-weight: bold;
            content: "#{escape_css_content(message)}";
          }

          body:after {
            content: "#{escape_css_content(backtrace)}";
          }
        CSS

        [ 200, { "Content-Type" => "text/css; charset=utf-8", "Content-Length" => body.bytesize.to_s }, [ body ] ]
      end

      # Escape special characters for use inside a CSS content("...") string
      def escape_css_content(content)
        content.
          gsub('\\', '\\\\005c ').
          gsub("\n", '\\\\000a ').
          gsub('"',  '\\\\0022 ').
          gsub('/',  '\\\\002f ')
      end

      # Compare the requests `HTTP_IF_NONE_MATCH` against the assets digest
      def etag_match?(asset, env)
        env["HTTP_IF_NONE_MATCH"] == etag(asset)
      end

      # Test if `?body=1` or `body=true` query param is set
      def body_only?(env)
        env["QUERY_STRING"].to_s =~ /body=(1|t)/
      end

      # Returns a 304 Not Modified response tuple
      def not_modified_response(asset, env)
        [ 304, cache_headers(env, asset), [] ]
      end

      # Returns a 200 OK response tuple
      def ok_response(asset, env)
        [ 200, headers(env, asset, asset.length), asset ]
      end

      def cache_headers(env, asset)
        headers = {}

        # Set caching headers
        headers["Cache-Control"] = "public"
        headers["Last-Modified"] = asset.mtime.httpdate
        headers["ETag"]          = etag(asset)

        # If the request url contains a fingerprint, set a long
        # expires on the response
        if path_fingerprint(env["PATH_INFO"])
          headers["Cache-Control"] << ", max-age=31536000"

        # Otherwise set `must-revalidate` since the asset could be modified.
        else
          headers["Cache-Control"] << ", must-revalidate"
          headers["Vary"] = "Accept-Encoding"
        end

        headers
      end

      def headers(env, asset, length)
        headers = {}

        # Set content encoding
        if asset.encoding
          headers["Content-Encoding"] = asset.encoding
        end

        # Set content length header
        headers["Content-Length"] = length.to_s

        # Set content type header
        if type = asset.content_type
          # Set charset param for text/* mime types
          if type.start_with?("text/") && asset.charset
            type += "; charset=#{asset.charset}"
          end
          headers["Content-Type"] = type
        end

        headers.merge(cache_headers(env, asset))
      end

      # Gets digest fingerprint.
      #
      #     "foo-0aa2105d29558f3eb790d411d7d8fb66.js"
      #     # => "0aa2105d29558f3eb790d411d7d8fb66"
      #
      def path_fingerprint(path)
        path[/-([0-9a-f]{7,40})\.[^.]+$/, 1]
      end

      # Helper to quote the assets digest for use as an ETag.
      def etag(asset)
        %("#{asset.digest}")
      end
  end
end
