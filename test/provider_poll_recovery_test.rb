# frozen_string_literal: true
require '/rsc/test/business_test'
require 'active_support/testing/time_helpers'
class ProviderPollRecoveryTest < NativeBusinessTest
  NativeBusinessTest.instance_methods(false).grep(/^test_/).each { |name| undef_method name }
  include ActiveSupport::Testing::TimeHelpers
  P=Jobs::DiscourseRscProviderPoll
  def setup
    super
    @live=[]; @enqueued=[]
    @live_method=P.method(:live_jobs);@enqueue_method=Jobs.method(:enqueue)
    current=self
    P.define_singleton_method(:live_jobs){current.instance_variable_get(:@live)}
    Jobs.define_singleton_method(:enqueue){|*args|current.instance_variable_get(:@enqueued)<<args}
    clear_keys
  end
  def clear_keys
    Discourse.redis.keys('rsc:provider-poll:*').each{|key|Discourse.redis.del(key)}
    Discourse.redis.del('rsc-data-sync','rsc-data-sync:missing-owner')
  end
  def teardown
    P.define_singleton_method(:live_jobs,@live_method)
    Jobs.define_singleton_method(:enqueue,@enqueue_method)
    clear_keys
    super
  end
  def scan(mode)
    Discourse.redis.del("rsc:provider-poll:#{mode}:recovery-check")
    P.enqueue_once(mode)
  end
  def test_interrupted_job_requires_two_observations_then_requeues_once
    travel_to(Time.utc(2026,10,30,12)) do
      key='rsc:provider-poll:crypto';Discourse.redis.set(key,'lost-token',ex:600)
      scan('crypto'); assert_empty @enqueued
      travel 29.seconds;scan('crypto');assert_empty @enqueued
      travel 1.second;scan('crypto');assert_equal 1,@enqueued.size
      refute_equal 'lost-token',Discourse.redis.get(key)
      scan('crypto');assert_equal 1,@enqueued.size
    end
  end
  def test_running_queued_or_retrying_owner_preserves_lease_and_resets_suspicion
    travel_to(Time.utc(2026,10,30,12)) do
      key='rsc:provider-poll:forex';Discourse.redis.set(key,'still-live',ex:600)
      scan('forex');travel 31.seconds
      @live=[['Jobs::DiscourseRscProviderPoll',{'mode'=>'forex','token'=>'still-live'}]]
      scan('forex');assert_empty @enqueued
      assert_equal 'still-live',Discourse.redis.get(key)
      assert_nil Discourse.redis.get("#{key}:missing-owner")
      @live=[];scan('forex');assert_empty @enqueued
      travel 31.seconds;scan('forex');assert_equal 1,@enqueued.size
    end
  end
  def test_replacement_owner_cannot_be_reaped_using_an_old_observation
    travel_to(Time.utc(2026,10,30,12)) do
      key='rsc:provider-poll:crypto';Discourse.redis.set(key,'old',ex:600)
      scan('crypto');travel 31.seconds
      Discourse.redis.set(key,'new',ex:600);scan('crypto')
      assert_equal 'new',Discourse.redis.get(key);assert_empty @enqueued
      observation=Discourse.redis.get("#{key}:missing-owner")
      Discourse.redis.set(key,'third',ex:600)
      assert_equal 0,R::ProviderHttp.evaluate(P::REAP,keys:[key,"#{key}:missing-owner"],argv:['new',observation])
      assert_equal 'third',Discourse.redis.get(key)
    end
  end
  def test_full_refresh_recovers_its_orphan_mutex_but_respects_manual_sync
    travel_to(Time.utc(2026,10,30,12)) do
      key='rsc:provider-poll:full';Discourse.redis.set(key,'lost',ex:600)
      Discourse.redis.set('rsc-data-sync','orphan',ex:600)
      @live=[['Jobs::DiscourseRscManualSync',{}]]
      scan('full');travel 31.seconds;scan('full')
      assert_equal 'orphan',Discourse.redis.get('rsc-data-sync')
      @live=[];scan('full');travel 31.seconds;scan('full')
      assert_nil Discourse.redis.get('rsc-data-sync')
    end
  end
  def test_old_task_cleanup_cannot_delete_replacement_token
    key='rsc:provider-poll:forex';Discourse.redis.set(key,'new',ex:600)
    P.new.execute(mode:'forex',token:'old')
    assert_equal 'new',Discourse.redis.get(key)
  end
  def test_job_inventory_covers_running_queued_retry_and_scheduled_jobs
    job=Struct.new(:klass,:args)
    entries=%w[crypto forex full].map{|mode|job.new('Jobs::DiscourseRscProviderPoll',[{'mode'=>mode,'token'=>'live'}])}
    manual=job.new('Jobs::DiscourseRscManualSync',[{'actor_user_id'=>1}])
    originals=[[Sidekiq::WorkSet,:new],[Sidekiq::Queue,:all],[Sidekiq::RetrySet,:new],[Sidekiq::ScheduledSet,:new]].map{|klass,name|[klass,name,klass.method(name)]}
    work=Struct.new(:job).new(entries[0])
    Sidekiq::WorkSet.define_singleton_method(:new){[['process','thread',work]]}
    Sidekiq::Queue.define_singleton_method(:all){[[entries[1]]]}
    Sidekiq::RetrySet.define_singleton_method(:new){[entries[2]]}
    Sidekiq::ScheduledSet.define_singleton_method(:new){[manual]}
    inventory=@live_method.call
    assert_equal 4,inventory.size
    assert_equal %w[crypto forex full],inventory.first(3).map{|_,args|args['mode']}
    assert_equal 'Jobs::DiscourseRscManualSync',inventory.last.first
  ensure
    originals&.each{|klass,name,method|klass.define_singleton_method(name,method)}
  end

  def test_full_job_does_not_block_or_obscure_an_orphan_data_mutex
    travel_to(Time.utc(2026,10,30,12)) do
      # DistributedMutex uses real Redis time and a numeric expiration value.
      Discourse.redis.set('rsc-data-sync',(Time.now.to_i+3600).to_s,ex:600)
      # Use Redis's clock even while the business clock travels in this test.
      Discourse.redis.set('rsc-data-sync',(Discourse.redis.time.first.to_i+600).to_s,ex:600)
      called=false
      P.new.with_data_sync { called=true }
      refute called
      scan('full');assert_empty @enqueued
      travel 31.seconds;scan('full')
      assert_nil Discourse.redis.get('rsc-data-sync')
      assert_equal 1,@enqueued.size
      P.new.with_data_sync { called=true }
      assert called
      assert_nil Discourse.redis.get('rsc-data-sync')
    end
  end

end
