# ---------------------------------------------------------------- CLOUDFRONT (HTTPS + caching)
# Visitors connect to CloudFront over HTTPS using its free *.cloudfront.net
# certificate (no domain needed). CloudFront caches the static UI at edge
# locations and forwards /api/* to the public ALB uncached.
#
# The ALB accepts traffic only from CloudFront: its security group allows only
# AWS's CloudFront origin-facing IP list, and its listener forwards only requests
# that carry a secret header that CloudFront adds. Known limitation: the
# CloudFront -> ALB hop is HTTP, because an ALB HTTPS listener needs a
# certificate for a domain we do not own.

resource "random_password" "origin_secret" {
  length  = 32
  special = false
}

data "aws_ec2_managed_prefix_list" "cloudfront" {
  name = "com.amazonaws.global.cloudfront.origin-facing"
}

data "aws_cloudfront_cache_policy" "disabled" {
  name = "Managed-CachingDisabled"
}

data "aws_cloudfront_origin_request_policy" "all_viewer_except_host" {
  name = "Managed-AllViewerExceptHostHeader"
}

# Static files: honour Nginx's Cache-Control (HTML no-cache, CSS/JS 1 hour)
resource "aws_cloudfront_cache_policy" "static" {
  name        = "${var.project}-static"
  min_ttl     = 0
  default_ttl = 3600
  max_ttl     = 86400

  parameters_in_cache_key_and_forwarded_to_origin {
    enable_accept_encoding_gzip   = true
    enable_accept_encoding_brotli = true
    cookies_config {
      cookie_behavior = "none"
    }
    headers_config {
      header_behavior = "none"
    }
    query_strings_config {
      query_string_behavior = "none"
    }
  }
}

resource "aws_cloudfront_distribution" "web" {
  enabled         = true
  comment         = "${var.project} three-tier web app"
  is_ipv6_enabled = true
  http_version    = "http2and3"
  price_class     = "PriceClass_200" # includes Asia / Middle East edges, cheaper than All

  origin {
    origin_id   = "web-alb"
    domain_name = aws_lb.web.dns_name

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "http-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }

    custom_header {
      name  = "X-Origin-Verify"
      value = random_password.origin_secret.result
    }
  }

  # Static UI (HTML, CSS, JS) and the web-tier endpoints
  default_cache_behavior {
    target_origin_id       = "web-alb"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD", "OPTIONS"]
    cached_methods         = ["GET", "HEAD"]
    cache_policy_id        = aws_cloudfront_cache_policy.static.id
    compress               = true
  }

  # REST API: every method, never cached, viewer headers forwarded
  ordered_cache_behavior {
    path_pattern             = "/api/*"
    target_origin_id         = "web-alb"
    viewer_protocol_policy   = "redirect-to-https"
    allowed_methods          = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods           = ["GET", "HEAD"]
    cache_policy_id          = data.aws_cloudfront_cache_policy.disabled.id
    origin_request_policy_id = data.aws_cloudfront_origin_request_policy.all_viewer_except_host.id
    compress                 = true
  }

  # Shows which web host answered (load-balancing demo): never cached
  ordered_cache_behavior {
    path_pattern           = "/web-info"
    target_origin_id       = "web-alb"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    cache_policy_id        = data.aws_cloudfront_cache_policy.disabled.id
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true # free *.cloudfront.net certificate
  }

  tags = { Name = "${var.project}-cdn" }
}

# The pipeline's smoke test reads the public URL from here
resource "aws_ssm_parameter" "public_url" {
  name  = "/${var.project}/public_url"
  type  = "String"
  value = "https://${aws_cloudfront_distribution.web.domain_name}"
}
