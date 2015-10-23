## Description

opsworks_interactor is a Ruby class that makes it easy to do rolling deploys to Amazon Opsworks. It certainly works for deploying Rails apps and would probably work for any other type of app as well.

It is designed to solve the common problem of synchronizing deploys to an Opsworks layer with one load balancer and two or more application servers.

It should work even with many instances and multiple load balancers.

## Rationale

The default Opsworks deploy command is quite rough. It deploys simultaneously on all instances in the stack and migrates the database on all of them.

This can result in migrations running simultaneously and interacting in strange ways. It can also result in downtime and dropped connections as the servers restart.

The solution is a rolling deploy that looks like this:

* Loop through all instances in layer
  * Deregister from ELB (elastic load balancer)
  * Wait connection draining timeout (set on the load balancer, default waits up to maximum of 300s before forcibly terminating connections)
  * Initiate deploy and run migrations
  * Register instance back to ELB
  * Wait for AWS to confirm the instance as registered and healthy
  * Once complete, move onto the next instance and repeat

Disappointingly Amazon doesn't offer a solution that does this, so I decided to write my own.

## Installation

Add to your Gemfile with

`gem 'opsworks_interactor'`

If you want to use Redis semaphore locking (recommended) you must also add

`gem 'redis-semaphore'`

## Usage

### Single deploys

There is a simple deploy command that can run on a single instance. Run it like this:

```
o = OpsworksInteractor.new(aws_access_key_id, aws_secret_access_key)
o.deploy(stack_id: YOUR_STACK_ID, app_id: YOUR_APP_ID, instance_id: YOUR_INSTANCE_ID)
```

This one doesn't do anything special, in fact it does exactly what would happen if you clicked 'deploy' in the Opsworks dashboard and chose to migrate the database.

### Rolling deploys

The second is a rolling deploy and this is where the magic happens.

To run a single rolling deploy, do it like this:

```
o = OpsworksInteractor.new(aws_access_key_id, aws_secret_access_key)
o.rolling_deploy(stack_id: YOUR_STACK_ID, layer_id: YOUR_LAYER_ID, app_id: YOUR_APP_ID)
```

This will run a rolling deploy of this app on this layer.

WARNING: The above command will work fine only if you run it once at a time. If you run more than one version of this command at the same time it could result in a condition where ALL instances become disconnected from the load balancer and your app goes offline. See the next section for how to avoid this.

### Rolling deploys with a semaphore lock

The best way is to run this command with a semaphore lock. The gem uses Redis to accomplish this and requires that `gem 'redis-semaphore'` be present in your Gemfile.

You must supply your Redis host details to use semaphore locking:

```
o = OpsworksInteractor.new(aws_access_key_id, aws_secret_access_key, redis: { host: 'your_redis_host', port: 42 })
o.rolling_deploy(stack_id: YOUR_STACK_ID, layer_id: YOUR_LAYER_ID, app_id: YOUR_APP_ID)
```

If you already use Redis in production you can re-use that same host.

Example command output deploying to a layer with one load balancer and two app servers:

```
Waiting for deploy lock...
Got lock. Running deploy...
Starting opsworks deploy for app FOOBAR-APP

=== Starting deploy for production-server-1 ===
Will detach instance i-FOO from falcon (remaining attached instances: i-BAR)
✓ detached from load-balancer-1
Deploy process running (id: XXXX-YYYY-ZZZZ)...
✓ deploy completed
Re-attaching instance i-FOO to all load balancers
✓ re-attached to load-balancer-1
=== Done deploying on production-server1 ===

=== Starting deploy for production-server2 ===
Will detach instance i-BAR from load-balancer-1 (remaining attached instances: i-FOO)
✓ detached from load-balancer-1
Deploy process running (id: ZZZZ-YYYY-XXXX)...
✓ deploy completed
Re-attaching instance i-BAR to all load balancers
✓ re-attached to load-balancer-1
=== Done deploying on production-server2 ===

SUCCESS: completed opsworks deploy for all instances on app FOOBAR-APP
Deploy complete. Releasing lock...
Lock released
```

#### Why do I need Redis?

If two or more rolling deploys were to execute simultanously, there is a possibility that all instances could be detached from the load balancer at the same time.

Although we check that other instances are attached before detaching, there could be a case where a deploy was running simultaneously on each instance of a pair. A race would then be possible where each machine sees the presence of the other instance and then both are detached. Now the load balancer has no instances to send traffic to.

Result: downtime and disaster.

By executing the code within the context of a lock on a shared global deploy mutex, deploys are forced to run in serial, and only one machine is detached at a time.

We could use file-locking to synchronize deploys on one single machine, but its possible this command could be issued from multiple machines so Redis is used to coordinate a mutual semaphore instead.

Result: disaster averted.

(This case is not as unlikely as it seems. If you were to configure this command to automatically deploy on a merge to master for example, two merges in short succession would result in two simultaneous deploys. In this case we would prefer to queue them and run in serial rather than running both simultaneously)

## Contributing

1. Fork it!
2. Create your feature branch: `git checkout -b my-new-feature`
3. Commit your changes: `git commit -am 'Add some feature'`
4. Push to the branch: `git push origin my-new-feature`
5. Submit a pull request :D

## License

MIT
