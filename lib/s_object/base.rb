module SObject
  class Base

    attr_reader :error, :url

    # Some fields cannot be posted to SF
    INVALID_FIELDS = %w(attributes)

    def initialize(fields = {})
      fields = fields.dup

      @id = fields['Id']

      if new_record?
        @url = "#{Authorization.service_url}/sobjects/#{type}"
      else
        @url = Authorization.instance_url + fields['attributes']['url']
        @type = fields['attributes']['type']
      end

      INVALID_FIELDS.each{ |field| fields.delete field }

      # Do basic type coercions and downcase field names
      @fields = fields.inject({}) do |memo, (key, value)|
        if value.is_a?(Hash) and value.has_key?('attributes')
          value = Factory.get(value['attributes']['type']).new(value)

        elsif value.is_a?(String) and (field_type(key) == 'date' or field_type(key) == 'datetime')
          value = DateTime.parse(value + ' UTC').to_gm_time

        end
        memo[key.downcase] = value
        memo
      end
    end

    def update_fields(updated_fields = {})
      @fields.merge!(updated_fields)
    end

    def fields
      @fields.delete_if{ |key, value| value.nil? }
    end

    def type
      @type || self.class.type
    end

    def id
      @id
    end

    def new_record?
      @id.nil?
    end

    def delete
      @response = Typhoeus::Request.delete(url, :headers => Authorization.headers)
      return @response.success?
    end

    def reload!
      self.class.find(id)
    end

    def save
      SObject.logger.info "Saving <#{type}:#{id}> to Salesforce."
      @response = Typhoeus::Request.run(
        url,
        :body => JSON.pretty_generate(saveable_fields),
        :headers => Authorization.headers,
        :method => save_method
      )

      return true if @response.success?

      @error = JSON.parse(@response.body).first
      raise SObject.error_class_for(error['message'], error['errorCode'])
    end

    def method_missing(method, *args)
      field_name = method.to_s

      # Setter method for field
      if field_name =~ /(.\w+)=$/ and (self.class.all_fields + fields.keys).include?($1)
        return fields[$1] = args.first

      # Getter method for field
      elsif (self.class.all_fields + fields.keys).include?(field_name)
        return fields[field_name]

      # Auto-resolve relationships
      #
      # Example:
      # @opportunity.account
      # #<SObject::Account:0x000001008e3950 ......>
      #
      elsif fields.has_key?(field_name + 'id') and field_type(field_name + 'id') == 'reference'
        return Factory.get(field_property(field_name + 'id', 'referenceTo').first).find(fields[field_name + 'id'])

      # Auto-resolve custom relationships named relationid__c
      #
      # Example:
      # @opportunity.my_relationid__c
      # => '001R000000fA6h3IAC'
      # @opportunity.my_relation__c
      # => #<SObject::MyRelation:0x000001008e3950 ......>
      #
      elsif fields.has_key?(field_name.sub(/__c$/, '') + 'id__c') and field_type(field_name.sub(/__c$/, '') + 'id__c') == 'reference'
        return Factory.get(field_property(field_name.sub(/__c$/, '') + 'id__c', 'referenceTo').first).find(fields[field_name.sub(/__c$/, '') + 'id__c'])

      # Auto-resolve custom relationships named relation_lookup__c
      #
      elsif fields.has_key?(field_name.sub(/__c$/, '') + '_lookup__c') and field_type(field_name.sub(/__c$/, '') + '_lookup__c') == 'reference'
        return Factory.get(field_property(field_name.sub(/__c$/, '') + '_lookup__c', 'referenceTo').first).find(fields[field_name.sub(/__c$/, '') + '_lookup__c'])


      else
        super

      end
    end

  private

    def save_method
      new_record? ? :post : :patch
    end

    def saveable_fields
      saveable_fields = {}

      fields.each do |key, value|
        key = key.downcase
        next unless field_exists?(key)
        next unless field_property(key, 'updateable')

        if field_type(key) == 'date'
          value = value.to_date.strftime(SF_DATETIME_FORMAT)
        elsif field_type(key) == 'datetime'
          value = value.to_gm_time.strftime(SF_DATETIME_FORMAT)
        end
        saveable_fields[key] = value
      end

      return saveable_fields
    end

    def metadata; self.class.metadata; end
    def field_type(field_name); self.class.field_type(field_name); end
    def field_exists?(field_name); self.class.field_exists?(field_name); end
    def field_property(field_name, property); self.class.field_property(field_name, property); end

  public


    class << self

      # Will GET the SObject's URL.
      # Automatically falls back to #find_throttled if the SObject has too many fields
      #
      # id           - The SObject ID
      #
      # Returns a SObject with all fields set.
      # Raises SObject::SalesforceError on error conditions
      #
      def find(id)
        find_by_id(id)
      rescue QueryTooComplicatedError
        find_throttled(id)
      end

      # Will GET the SObject's URL.
      # Caveat: Sometimes SObjects have too many fields to GET in one call.
      #
      # id           - The SObject ID
      #
      # Returns a SObject with all fields set.
      # Raises SObject::QueryTooComplicatedError if the SObject has too many fields.
      # Raises SObject::SalesforceError on other error conditions
      #
      def find_by_id(id)
        response = Typhoeus::Request.get(
          Authorization.service_url + "/sobjects/#{type}/#{id}",
          :headers => Authorization.headers
        )

        parsed_response = JSON.parse(response.body)

        unless response.success?
          error_code    = parsed_response.first["errorCode"]
          error_message = parsed_response.first["message"]
          raise SObject.error_class_for(error_message + "<#{type}:#{id}>", error_code)
        end

        new(parsed_response)
      end

      # Will query Salesforce for a SObject, selecting only the fields specified
      #
      # id           - The SObject ID
      # query_fields - The fields to query on the SObject
      #
      # Returns a SObject with the selected fields set.
      # Raises SObject::Error if no SObject with the specified ID was found.
      #
      def find_fields_by_id(id, query_fields = ['id'])
        query_fields = Array(query_fields)
        resulting_fields = Query.new(
          :where => "id = '#{id}'",
          :type  => type,
          :fields => query_fields
        ).records.first
        raise ObjectNotFoundError.new("#{type} with ID #{id} not found.", 'NOT_FOUND') unless resulting_fields
        return resulting_fields
      end

      # Will iterate over chunks of fields to build up a complete SObject
      # in case of a QUERY_TOO_COMPLICATED exception
      #
      # id - The SObject ID
      #
      # returns a SObject with all fields set
      #
      def find_throttled(id)
        fields_hash = {}
        all_fields.each_slice(20) do |slice|
          fields_hash.merge!(find_fields_by_id(id, slice))
        end
        new(fields_hash)
      end

      def metadata
        return @metadata if @metadata
        @response = Typhoeus::Request.get(
          Authorization.service_url + "/sobjects/#{type}/describe",
          :headers => Authorization.headers
        )

        @metadata = JSON.parse(@response.body)

        unless @response.success?
          error_code    = @metadata.first["errorCode"]
          error_message = @metadata.first["message"]
          raise SObject.error_class_for(error_message + "<#{type}:#{id}>", error_code)
        end

        if @metadata['fields']
          @metadata['fields'].each{ |field| field['name'] = field['name'].downcase }
        end
        return @metadata
      end

      def count
        return query.total_size
      end

      def first
        return find(query.records.first['Id'])
      end

      # Fields defined here will be queried only when using a SOQL-Query to fetch
      # the record.
      # This means, that records loaded with .find_by_id won't have fields like
      # owner.id defined. One would have to use .where("id = 'xxxxx'") when these
      # are needed.
      #
      def fields
        all_fields
      end

      def all_fields
        @all_fields ||= (metadata['fields'].collect{ |field| field['name'] }).uniq.sort
      end

      def field_type(field_name)
        field_property(field_name, 'type')
      end

      def field_property(field_name, property)
        raise Error.new("Field <#{type}##{field_name}> doesn't exist.") unless field_metadata(field_name)
        return field_metadata(field_name)[property]
      end

      def field_metadata(field_name)
        field_name = field_name.downcase
        metadata['fields'].find{ |field| field['name'] == field_name }
      end

      def field_exists?(field_name)
        !!field_metadata(field_name)
      end

      def create(fields = {})
        new(fields).save
      end

      def type
        raise NotImplementedError.new('You need to define the type of your SObject in class method `type`')
      end

    private

      def query
        return Query.new(
          :type => type,
          :fields => 'id'
        )
      end

    end # class << self
  end
end