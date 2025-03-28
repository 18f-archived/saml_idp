# The contents of this file are subject to the terms
# of the Common Development and Distribution License
# (the License). You may not use this file except in
# compliance with the License.
#
# You can obtain a copy of the License at
# https://opensso.dev.java.net/public/CDDLv1.0.html or
# opensso/legal/CDDLv1.0.txt
# See the License for the specific language governing
# permission and limitations under the License.
#
# When distributing Covered Code, include this CDDL
# Header Notice in each file and include the License file
# at opensso/legal/CDDLv1.0.txt.
# If applicable, add the following below the CDDL Header,
# with the fields enclosed by brackets [] replaced by
# your own identifying information:
# "Portions Copyrighted [year] [name of copyright owner]"
#
# $Id: xml_sec.rb,v 1.6 2007/10/24 00:28:41 todddd Exp $
#
# Copyright 2007 Sun Microsystems Inc. All Rights Reserved
# Portions Copyrighted 2007 Todd W Saxton.

require 'openssl'
require 'nokogiri'
require 'digest/sha1'
require 'digest/sha2'

module SamlIdp
  module XMLSecurity
    class SignedDocument
      class ValidationError < StandardError
        attr_reader :error_code

        def initialize(msg = nil, error_code = nil)
          @error_code = error_code
          super(msg)
        end
      end

      C14N = 'http://www.w3.org/2001/10/xml-exc-c14n#'
      DSIG = 'http://www.w3.org/2000/09/xmldsig#'
      DS_NS = { 'ds' => DSIG }

      attr_accessor :document

      def initialize(response)
        @document = Nokogiri.XML(response)
      end

      def validate(idp_certificate, options = {}, soft: true)
        if request_cert && Base64.decode64(request_cert) != idp_certificate.to_der
          return false if soft

          raise ValidationError.new('Request certificate not valid or registered',
                                    :request_cert_not_registered)
        end

        validate_doc(Base64.encode64(idp_certificate.to_pem), soft, options)
      end

      def request_cert
        return false if cert_element.blank?

        if cert_element.text.blank?
          raise ValidationError.new(
            'Certificate element present in response (ds:X509Certificate) but evaluating to nil',
            :no_certificate_in_request
          )
        end

        cert_element.text
      end

      def validate_doc(base64_cert, soft = true, options = {})
        if options[:get_params] && options[:get_params][:Signature]
          validate_doc_params_signature(base64_cert, soft, options[:get_params])
        else
          validate_doc_embedded_signature(
            base64_cert,
            soft
          )
        end
      end

      private

      def signature_algorithm(options)
        if options[:get_params] && options[:get_params][:SigAlg]
          algorithm(options[:get_params][:SigAlg])
        else
          ref_elem = document.at_xpath('//ds:Reference | //Reference', DS_NS)
          return nil unless ref_elem

          algorithm(ref_elem.at_xpath('//ds:DigestMethod | //DigestMethod', DS_NS))
        end
      end

      def fingerprint_cert(cert, options)
        digest_algorithm = signature_algorithm(options)
        digest_algorithm&.hexdigest(cert.to_der)
      end

      def fingerprint_cert_sha1(cert)
        OpenSSL::Digest::SHA1.hexdigest(cert.to_der)
      end

      def request?
        document.root.name != 'Response'
      end

      # matches RubySaml::Utils
      def build_query(params)
        type, data, relay_state, sig_alg = params.values_at(:type, :data, :relay_state, :sig_alg)

        url_string = "#{type}=#{CGI.escape(data)}"
        url_string << "&RelayState=#{CGI.escape(relay_state)}" if relay_state
        url_string << "&SigAlg=#{CGI.escape(sig_alg)}"
      end

      def validate_doc_params_signature(base64_cert, soft = true, params)
        document_type = request? ? :SAMLRequest : :SAMLResponse

        canon_string = build_query(
          type: document_type,
          data: params[document_type.to_sym],
          relay_state: params[:RelayState],
          sig_alg: params[:SigAlg]
        )

        log '***** validate_doc_params_signature: verify_signature:'

        verify_signature(
          base64_cert,
          params[:SigAlg],
          Base64.decode64(params[:Signature]),
          canon_string,
          soft
        )
      end

      def validate_doc_embedded_signature(
        base64_cert,
        soft = true
      )
        # check for inclusive namespaces
        inclusive_namespaces = extract_inclusive_namespaces

        sig_element = document.at_xpath('//ds:Signature | //Signature', DS_NS)
        signed_info_element = sig_element.at_xpath('./ds:SignedInfo | //SignedInfo', DS_NS)

        canon_algorithm = canon_algorithm(
          sig_element.at_xpath('//ds:CanonicalizationMethod | //CanonicalizationMethod', DS_NS)
        )

        canon_string = signed_info_element.canonicalize(canon_algorithm)
        # check digests
        sig_element.xpath('//ds:Reference | //Reference', DS_NS).each do |ref|
          uri = ref.attribute('URI').value

          hashed_element = document.dup.at_xpath("//*[@ID='#{uri[1..-1]}']")
          # removing the Signature node and children to get digest
          hashed_element.at_xpath('//ds:Signature | //Signature', DS_NS).remove

          canon_algorithm = canon_algorithm(
            ref.at_xpath('//ds:CanonicalizationMethod | //CanonicalizationMethod', DS_NS)
          )

          canon_hashed_element = hashed_element.canonicalize(
            canon_algorithm,
            inclusive_namespaces
          )

          digest_algorithm = digest_method_algorithm(ref)

          hash = digest_algorithm.digest(canon_hashed_element)

          digest_value = Base64.decode64(ref.at_xpath(
            '//ds:DigestValue | //DigestValue', DS_NS
          ).text)

          next if digests_match?(hash, digest_value)

          return false if soft

          raise ValidationError.new('Digest mismatch', :digest_mismatch)
        end

        base64_signature = sig_element.at_xpath(
          '//ds:SignatureValue | //SignatureValue', DS_NS
        ).text
        signature = Base64.decode64(base64_signature)

        sig_alg = sig_element.at_xpath('//ds:SignatureMethod | //SignatureMethod', DS_NS)

        log '***** validate_doc_embedded_signature: verify_signature:'
        verify_signature(base64_cert, sig_alg, signature, canon_string, soft)
      end

      def digest_method_algorithm(ref)
        algorithm(ref.at_xpath('//ds:DigestMethod | //DigestMethod', DS_NS))
      end

      def verify_signature(base64_cert, sig_alg, signature, canon_string, soft)
        cert_text = Base64.decode64(base64_cert)
        cert = OpenSSL::X509::Certificate.new(cert_text)
        signature_algorithm = algorithm(sig_alg)

        if signature_algorithm != SamlIdp.config.algorithm
          return false if soft

          raise ValidationError.new(
            "Signature Algorithm needs to be #{SamlIdp.config.algorithm.new.name}",
            :wrong_sig_algorithm
          )
        end

        unless cert.public_key.verify(signature_algorithm.new, signature, canon_string)
          return false if soft

          raise ValidationError.new('Key validation error', :key_validation_error)
        end

        true
      end

      def digests_match?(hash, digest_value)
        hash == digest_value
      end

      def canon_algorithm(element)
        algorithm = element.attribute('Algorithm').value if element
        case algorithm
        when 'http://www.w3.org/2001/10/xml-exc-c14n#'
          Nokogiri::XML::XML_C14N_EXCLUSIVE_1_0
        when 'http://www.w3.org/TR/2001/REC-xml-c14n-20010315'
          Nokogiri::XML::XML_C14N_1_0
        when 'http://www.w3.org/2006/12/xml-c14n11'
          Nokogiri::XML::XML_C14N_1_1
        else
          Nokogiri::XML::XML_C14N_EXCLUSIVE_1_0
        end
      end

      def algorithm(element)
        algorithm = element
        algorithm = element.attribute('Algorithm').value if algorithm.is_a?(Nokogiri::XML::Element)
        log "~~~~~~ Algorithm: #{algorithm}"
        algorithm = algorithm && algorithm =~ /(rsa-)?sha(.*?)$/i && ::Regexp.last_match(2).to_i
        case algorithm
        when 256
          log 'Request signed with SHA256'
          OpenSSL::Digest::SHA256
        when 384
          log 'Request signed with SHA384'
          OpenSSL::Digest::SHA384
        when 512
          log 'Request signed with SHA512'
          OpenSSL::Digest::SHA512
        else
          log 'Request using default SHA1'
          OpenSSL::Digest::SHA1
        end
      end

      def extract_inclusive_namespaces
        document.at_xpath(
          '//ec:InclusiveNamespaces', { 'ec' => C14N }
        )&.attr('PrefixList')&.split(' ') || []
      end

      def cert_element
        @cert_element ||= document.at_xpath('//ds:X509Certificate | //X509Certificate', DS_NS)
      end

      def log(msg, level: :debug)
        if Rails && Rails.logger
          Rails.logger.send(level, msg)
        else
          puts msg
        end
      end
    end
  end
end
