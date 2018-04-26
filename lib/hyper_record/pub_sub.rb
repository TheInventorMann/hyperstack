module HyperRecord
  module PubSub
    def self.included(base)
      base.extend(HyperRecord::PubSub::ClassMethods)
    end

    module ClassMethods
      def _pusher_client
        Hyperloop.pusher_instance ||= Pusher::Client.new(
          app_id: Hyperloop.pusher[:app_id],
          key: Hyperloop.pusher[:key],
          secret: Hyperloop.pusher[:secret],
          cluster: Hyperloop.pusher[:cluster]
        )
      end

      def publish_relation(base_record, relation_name, record = nil)
        subscribers = Hyperloop.redis_instance.hgetall("HRPS__#{base_record.class}__#{base_record.id}__#{relation_name}")
        time_now = Time.now.to_f
        scrub_time = time_now - 24.hours.to_f
        message = {
          record_type: base_record.class.to_s,
          id: base_record.id,
          updated_at: base_record.updated_at,
          relation: relation_name
        }
        if record
          message[:cause] = {}
          message[:cause][:record_type] = record.class.to_s
          message[:cause][:id] = record.id
          message[:cause][:updated_at] = record.updated_at
          message[:cause][:destroyed] = true if record.destroyed?
        end
        subscribers.each do |session_id, last_requested|
          if last_requested.to_f < scrub_time
            Hyperloop.redis_instance.hdel("HRPS__#{base_record.class}__#{base_record.id}__#{relation_name}", session_id)
            next
          end
          if Hyperloop.resource_transport == :pusher
            _pusher_client.trigger("hyper-record-update-channel-#{session_id}", 'update', message)
          end
        end
      end

      def publish_record(record)
        subscribers = Hyperloop.redis_instance.hgetall("HRPS__#{record.class}__#{record.id}")
        time_now = Time.now.to_f
        scrub_time = time_now - 24.hours.to_f

        message = {
          record_type: record.class.to_s,
          id: record.id,
          updated_at: record.updated_at
        }
        message[:destroyed] = true if record.destroyed?

        subscribers.each_slice(50) do |slice|
          channel_array= []
          slice.each do |session_id, last_requested|
            if last_requested.to_f < scrub_time
              Hyperloop.redis_instance.hdel("HRPS__#{record.class}__#{record.id}", session_id)
              next
            end
            channel_array << "hyper-record-update-channel-#{session_id}"
          end
          if Hyperloop.resource_transport == :pusher && channel_array.size > 0
            _pusher_client.trigger(channel_array, 'update', message)
          end
        end
        Hyperloop.redis_instance.del("HRPS__#{record.class}__#{record.id}") if record.destroyed?
      end

      def publish_scope(record_class, scope_name)
        subscribers = Hyperloop.redis_instance.hgetall("HRPS__#{record_class}__scope__#{scope_name}")
        time_now = Time.now.to_f
        scrub_time = time_now - 24.hours.to_f
        subscribers.each do |session_id, last_requested|
          if last_requested.to_f < scrub_time
            Hyperloop.redis_instance.hdel("HRPS__#{record_class}__scope__#{scope_name}", session_id)
            next
          end
          message = {
            record_type: record_class.to_s,
            scope: scope_name
          }
          if Hyperloop.resource_transport == :pusher
            _pusher_client.trigger("hyper-record-update-channel-#{session_id}", 'update', message)
          end
        end
      end

      def subscribe_relation(relation, base_record = nil, relation_name = nil)
        return unless session.id
        time_now = Time.now.to_f.to_s
        session_id = session.id.to_s
        Hyperloop.redis_instance.pipelined do
          if relation.is_a?(Enumerable)
            # has_many
            relation.each do |record|
              Hyperloop.redis_instance.hset("HRPS__#{record.class}__#{record.id}", session_id, time_now)
            end
          elsif !relation.nil?
            # has_one, belongs_to
            Hyperloop.redis_instance.hset("HRPS__#{relation.class}__#{relation.id}", session_id, time_now)
          end
          Hyperloop.redis_instance.hset("HRPS__#{base_record.class}__#{base_record.id}__#{relation_name}", session_id, time_now) if base_record && relation_name
        end
      end

      def subscribe_record(record)
        return unless session.id
        Hyperloop.redis_instance.hset "HRPS__#{record.class}__#{record.id}", session.id.to_s, Time.now.to_f.to_s
      end

      def subscribe_scope(collection, record_class = nil, scope_name = nil)
        return unless session.id
        time_now = Time.now.to_f.to_s
        session_id = session.id.to_s
        Hyperloop.redis_instance.pipelined do
          if collection.is_a?(Enumerable)
            collection.each do |record|
              Hyperloop.redis_instance.hset("HRPS__#{record.class}__#{record.id}", session_id, time_now)
            end
          end
          Hyperloop.redis_instance.hset("HRPS__#{record_class}__scope__#{scope_name}", session_id, time_now) if record_class && scope_name
        end
      end

      def pub_sub_relation(relation, base_record, relation_name, causing_record = nil)
        subscribe_relation(relation, base_record, relation_name)
        publish_relation(base_record, relation_name, causing_record)
      end

      def pub_sub_record(record)
        subscribe_record(record)
        publish_record(record)
      end

      def pub_sub_scope(collection, record_class, scope_name)
        subscribe_scope(collection, record_class, scope_name)
        publish_scope(record_class, scope_name)
      end

      def session
        @_hyper_resource_session
      end
    end

    # instance methods

    def publish_relation(base_record, relation_name, record = nil)
      self.class.publish_relation(base_record, relation_name, record)
    end

    def publish_record(record)
      self.class.publish_record(record)
    end

    def publish_scope(record_class, scope_name)
      self.class.publish_scope(record_class, scope_name)
    end

    def subscribe_relation(relation, base_record = nil, relation_name = nil)
      self.class.subscribe_relation(relation, base_record, relation_name)
    end

    def subscribe_record(record)
      self.class.subscribe_record(record)
    end

    def subscribe_scope(collection, record_class = nil, scope_name = nil)
      self.class.subscribe_scope(collection, record_class, scope_name)
    end

    def pub_sub_relation(relation, base_record, relation_name, causing_record = nil)
      self.class.pub_sub_relation(relation, base_record, relation_name, causing_record)
    end

    def pub_sub_record(record)
      self.class.pub_sub_record(record)
    end

    def pub_sub_scope(collection, record_class, scope_name)
      self.class.pub_sub_scope(collection, record_class, scope_name)
    end
  end
end
