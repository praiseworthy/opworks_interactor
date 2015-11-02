require 'aws-sdk'
require 'timeout'
class OpsworksInteractor
  begin
    require 'redis-semaphore'
  rescue LoadError
    # suppress, this is handled at runtime in with_deploy_lock
  end

  DeployLockError = Class.new(StandardError)

  # All opsworks endpoints are in the us-east-1 region, see:
  # http://docs.aws.amazon.com/opsworks/latest/userguide/cli-examples.html
  OPSWORKS_REGION = 'us-east-1'

  def initialize(access_key_id, secret_access_key, redis: nil)
    # All opsworks endpoints are always in the OPSWORKS_REGION
    @opsworks_client = Aws::OpsWorks::Client.new(
      access_key_id:     access_key_id,
      secret_access_key: secret_access_key,
      region: OPSWORKS_REGION
    )

    @elb_client = Aws::ElasticLoadBalancing::Client.new(
      access_key_id:     access_key_id,
      secret_access_key: secret_access_key,
      region: ENV['AWS_REGION'] || OPSWORKS_REGION
    )

    # Redis host and port may be supplied if you want to run your deploys with
    # mutual exclusive locking (recommended)
    # Example redis config: { host: 'foo', port: 42 }
    @redis = redis
  end

  # Runs only ONE rolling deploy at a time.
  #
  # If another one is currently  running, waits for it to finish before starting
  def rolling_deploy(**kwargs)
    with_deploy_lock do
      rolling_deploy_without_lock(**kwargs)
    end
  end

  # Deploys the given app_id on the given instance_id in the given stack_id
  #
  # Blocks until AWS confirms that the deploy was successful
  #
  # Returns a Aws::OpsWorks::Types::CreateDeploymentResult
  def deploy(stack_id:, app_id:, instance_id:, deploy_timeout: 30.minutes)
    response = @opsworks_client.create_deployment(
      stack_id:     stack_id,
      app_id:       app_id,
      instance_ids: [instance_id],
      command: {
        name: 'deploy',
        args: {
          'migrate' => ['true'],
        }
      }
    )

    log("Deploy process running (id: #{response[:deployment_id]})...")

    wait_until_deploy_completion(response[:deployment_id], deploy_timeout)

    log("✓ deploy completed")

    response
  end

  private

  # Polls Opsworks for timeout seconds until deployment_id has completed
  def wait_until_deploy_completion(deployment_id, timeout)
    started_at = Time.now
    Timeout::timeout(timeout) do
      @opsworks_client.wait_until(
        :deployment_successful,
        deployment_ids: [deployment_id]
      ) do |w|
        # disable max attempts
        w.max_attempts = nil
      end
    end
  end

  # Loop through all instances in layer
  # Deregister from ELB (elastic load balancer)
  # Wait connection draining timeout (default up to maximum of 300s)
  # Initiate deploy and run migrations
  # Register instance back to ELB
  # Wait for AWS to confirm the instance as registered and healthy
  # Once complete, move onto the next instance and repeat
  def rolling_deploy_without_lock(stack_id:, layer_id:, app_id:)
    log("Starting opsworks deploy for app #{app_id}\n\n")

    instances = @opsworks_client.describe_instances(layer_id: layer_id)[:instances]

    instances.each do |instance|
      begin
        log("=== Starting deploy for #{instance.hostname} ===")

        load_balancers = detach_from_elbs(instance: instance)

        deploy(
          stack_id: stack_id,
          app_id: app_id,
          instance_id: instance.instance_id
        )
      ensure
        attach_to_elbs(instance: instance, load_balancers: load_balancers) if load_balancers

        log("=== Done deploying on #{instance.hostname} ===\n\n")
      end
    end

    log("SUCCESS: completed opsworks deploy for all instances on app #{app_id}")
  end

  # Executes the given block only after obtaining an exclusive lock on the
  # deploy semaphore.
  #
  # EXPLANATION
  # ===========
  #
  # If two or more rolling deploys were to execute simultanously, there is a
  # possibility that all instances could be detached from the load balancer
  # at the same time.
  #
  # Although we check that other instances are attached before detaching, there
  # could be a case where a deploy was running simultaneously on each instance
  # of a pair. A race would then be possible where each machine sees the
  # presence of the other instance and then both are detached. Now the load
  # balancer has no instances to send traffic to
  #
  # Result: downtime and disaster.
  #
  # By executing the code within the context of a lock on a shared global deploy
  # mutex, deploys are forced to run in serial, and only one machine is detached
  # at a time.
  #
  # Result: disaster averted.
  DEPLOY_WAIT_TIMEOUT = 600 # max seconds to wait in the queue, once this has expired the process will raise
  def with_deploy_lock
    if !defined?(Redis::Semaphore)
      log(<<-MSG.squish)
        Redis::Semaphore not found, will attempt to deploy without locking.\n
        WARNING: this could cause undefined behavior if two or more deploys
        are run simultanously!\n
        It is recommended that you use semaphore locking. To fix this, add
        `gem 'redis-semaphore'` to your Gemfile and run `bundle install`.
      MSG

      yield
    elsif !@redis
      log(<<-MSG.squish)
        Redis::Semaphore was found but :redis was not set, will attempt to
        deploy without locking.\n
        WARNING: this could cause undefined behavior if two or more deploys
        are run simultanously!\n
        It is recommended that you use semaphore locking. To fix this, supply a
        :redis hash like { host: 'foo', port: 42 } .
      MSG

      yield
    else
      s = Redis::Semaphore.new(:deploy, **@redis)

      log("Waiting for deploy lock...")

      success = s.lock(DEPLOY_WAIT_TIMEOUT) do
        log("Got lock. Running deploy...")
        yield
        log("Deploy complete. Releasing lock...")
        true
      end

      if success
        log("Lock released")
        true
      else
        fail(DeployLockError, "could not get deploy lock within #{DEPLOY_WAIT_TIMEOUT} seconds")
      end
    end
  end

  # Takes a Aws::OpsWorks::Types::Instance
  #
  # Detaches the provided instance from all of its load balancers
  #
  # Returns the detached load balancers as an array of
  # Aws::ElasticLoadBalancing::Types::LoadBalancerDescription
  #
  # Blocks until AWS confirms that all instances successfully detached before
  # returning
  #
  # Does not wait and instead returns an empty array if no load balancers were
  # found for this instance
  def detach_from_elbs(instance:)
    unless instance.is_a?(Aws::OpsWorks::Types::Instance)
      fail(ArgumentError, "instance must be a Aws::OpsWorks::Types::Instance struct")
    end

    all_load_balancers =  @elb_client.describe_load_balancers
                          .load_balancer_descriptions

    load_balancers = detach_from(all_load_balancers, instance)

    lb_wait_params = []

    load_balancers.each do |lb|
      params = {
        load_balancer_name: lb.load_balancer_name,
        instances: [{ instance_id: instance.ec2_instance_id }]
      }

      remaining_instances = @elb_client
                            .deregister_instances_from_load_balancer(params)
                            .instances

      log(<<-MSG.squish)
        Will detach instance #{instance.ec2_instance_id} from
        #{lb.load_balancer_name} (remaining attached instances:
        #{remaining_instances.map(&:instance_id).join(', ')})
      MSG

      lb_wait_params << params
    end

    if lb_wait_params.any?
      lb_wait_params.each do |params|
        # wait for all load balancers to list the instance as deregistered
        @elb_client.wait_until(:instance_deregistered, params)

        log("✓ detached from #{params[:load_balancer_name]}")
      end
    else
      log("No load balancers found for instance #{instance.ec2_instance_id}")
    end

    load_balancers
  end

  # Accepts load_balancers as array of
  # Aws::ElasticLoadBalancing::Types::LoadBalancerDescription
  # and instances as a Aws::OpsWorks::Types::Instance
  #
  # Returns only the LoadBalancerDescription objects that have the instance
  # attached and should be detached from
  #
  # Will not include a load balancer in the returned collection if the
  # supplied instance is the ONLY one connected. Detaching the sole remaining
  # instance from a load balancer would probably cause undesired results.
  def detach_from(load_balancers, instance)
    check_arguments(instance: instance, load_balancers: load_balancers)

    load_balancers.select do |lb|
      matched_instance = lb.instances.any? do |lb_instance|
        instance.ec2_instance_id == lb_instance.instance_id
      end

      if matched_instance && lb.instances.count > 1
        # We can detach this instance safely because there is at least one other
        # instance to handle traffic
        true
      elsif matched_instance && lb.instances.count == 1
        # We can't detach this instance because it's the only one
        log(<<-MSG.squish)
          Will not detach #{instance.ec2_instance_id} from load balancer
          #{lb.load_balancer_name} because it is the only instance connected
        MSG

        false
      else
        # This load balancer isn't attached to this instance
        false
      end
    end
  end

  # Takes an instance as a Aws::OpsWorks::Types::Instance
  # and load balancers as an array of
  # Aws::ElasticLoadBalancing::Types::LoadBalancerDescription
  #
  # Attaches the provided instance to the supplied load balancers and blocks
  # until AWS confirms that the instance is attached to all load balancers
  # before returning
  #
  # Does nothing and instead returns an empty hash if load_balancers is empty
  #
  # Otherwise returns a hash of load balancer names each with a
  # Aws::ElasticLoadBalancing::Types::RegisterEndPointsOutput
  def attach_to_elbs(instance:, load_balancers:)
    check_arguments(instance: instance, load_balancers: load_balancers)

    if load_balancers.empty?
      log("No load balancers to attach to")
      return {}
    end

    lb_wait_params = []
    registered_instances = {} # return this

    load_balancers.each do |lb|
      params = {
        load_balancer_name: lb.load_balancer_name,
        instances: [{ instance_id: instance.ec2_instance_id }]
      }

      result = @elb_client.register_instances_with_load_balancer(params)

      registered_instances[lb.load_balancer_name] = result
      lb_wait_params << params
    end

    log("Re-attaching instance #{instance.ec2_instance_id} to all load balancers")

    # Wait for all load balancers to list the instance as registered
    lb_wait_params.each do |params|
      @elb_client.wait_until(:instance_in_service, params)

      log("✓ re-attached to #{params[:load_balancer_name]}")
    end

    registered_instances
  end

  # Fails unless arguments are of the expected types
  def check_arguments(instance:, load_balancers:)
    unless instance.is_a?(Aws::OpsWorks::Types::Instance)
      fail(ArgumentError,
           ":instance must be a Aws::OpsWorks::Types::Instance struct")
    end
    unless load_balancers.respond_to?(:each) &&
           load_balancers.all? do |lb|
             lb.is_a?(Aws::ElasticLoadBalancing::Types::LoadBalancerDescription)
           end
      fail(ArgumentError, <<-MSG.squish)
        :load_balancers must be a collection of
        Aws::ElasticLoadBalancing::Types::LoadBalancerDescription objects
      MSG
    end
  end

  # Could use Rails logger here instead if you wanted to
  def log(message)
    puts message
  end
end
