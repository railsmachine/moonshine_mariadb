## Description

We used to consider this plugin beta, but we've now been using it for over a year and have several customers on it.  We consider it... *awesome*.

This is a [Moonshine](http://github.com/railsmachine/moonshine) recipe for installing and configuring [MariaDB](http://mariadb.org), and setting up a Galera Cluster for replication and failover.  If there's only one server in the database_servers list, it will run MariaDB in standalone mode without any cluster configuration.  If there are two or more (3 nodes are recommended), then it will create the configuration for a cluster.  We've provided several cap tasks to properly configure and bootstrap the cluster (see the Bootstrapping the Cluster section)

## Gotchas and Warnings

* You should *never* restart all the nodes in your cluster at the same time, or you'll need to go through the setup cap tasks again.
* If you change any of the mariadb settings, you'll need to run the mariadb:restart task, as it's not restarted during deploy (for the reason stated above)
* You can use this with a single server and you get the benefits of MariaDB over old school MySQL, but we *highly* recommend using galera replication. It's faster, more reliable, and easier to recover from if something goes wrong.

## Installation

* Rails 2: <code>script/plugin install git://github.com/railsmachine/moonshine_mariadb.git --force</code>
* Rails 3: <code>script/rails plugin install git://github.com/railsmachine/moonshine_mariadb.git --force</code>
* Rails 4

Make sure you have the plugger gem in your Gemfile and then run: <code>plugger install git://github.com/railsmachine/moonshine_mariadb.git --force</code>
  
## Configuration

The plugin installs the Galera Cluster version of MariaDB and supports setting up a three node cluster rather nicely, though it should work fine with just one server.  If you're going to set up a cluster, there are some configuration things you need to worry about:

* You need to set <code>wsrep_cluster_address</code> to <code>gcomm://ipaddress0,ipaddress1,ipaddress2</code> (where ipdaddress0,1 & 2 are the ip addresses of the nodes in your cluster).  If you only have one server in the database_servers list, then this setting isn't necessary.
* If you use iptables, and you should, you'll need to open the following ports:
  * 3306 - Just like for MySQL, any server who needs to talk to the database needs access to this port.
  * 9200 - If you're going to use haproxy to monitor the health of the nodes in the cluster, then they need to be able to talk to all nodes on this port.
  * 4567 & 4444 - All three nodes need to talk to each other on these ports for exchanging node state and rsyncing.
* allowed_hosts - You need to make sure that every server that needs to talk to the database has its IP address in this array.

If you're using [moonshine_multi_server](http://github.com/railsmachine/moonshine_multi_server), here's a configuration builder to help get you started:

<pre><code>def build_mariadb_configuration
  internal_ips = database_servers.map do |server|
    server[:internal_ip]
  end
  
  cluster_address = []
  
  database_servers.each do |server|
    cluster_address << server[:internal_ip]
  end
  
  allowed_hosts = internal_ips
  allowed_hosts << 'localhost'
  
  servers_with_rails_env.each do |server|
    allowed_hosts << server[:internal_ip]
  end
  
  {
    :gcomm_cluster_address => "gcomm://#{cluster_address.join(",")}",
    :wsrep_node_address => Facter.value(:ipaddress_eth1),
    :wsrep_sst_receive_address => Facter.value(:ipaddress_eth1),
    :wsrep_node_name => Facter.value(:hostname),
    :wsrep_cluster_name => "rmcom",
    :allowed_hosts => allowed_hosts
  }
  
end

def servers_with_rails_env
  (application_servers + database_servers + haproxy_servers)
end</code></pre>

## The Manifest

Since MariaDB is a replacement for MySQL, here's what your database_manifest.rb should look like (pretty much):

<pre><code>require "#{File.dirname(__FILE__)}/base_manifest.rb"

class DatabaseManifest < BaseManifest
  include Moonshine::MariaDb
  recipe :default_system_config
  recipe :non_rails_recipes
  configure :iptables => build_mariadb_iptables_rules
  configure :mariadb => build_mariadb_configuration
  configure :sysctl => {
    'net.ipv4.tcp_tw_reuse' => 1,
    'net.ipv4.neigh.default.gc_interval' => 3600
  }
  recipe :iptables
  recipe :sysctl
  recipe :mariadb
end</code></pre>

If you're using MariaDB on a single server, you should be able to remove the mysql recipe and add mariadb instead.  And since you're on a single server, you don't need to worry about iptables or all of the cluster configuration.

## Bootstrapping the Cluster

If you're creating a cluster for the first time, the first deploy after MariaDB is installed will probably fail starting MySQL since it can't connect to an existing node.  That's where the cap tasks come in.  If you follow the steps in this order, you should end up with a replicated cluster all ready to shove lots of data into:

* <code>cap STAGE mariadb:setup_master</code> - This uploads the master_setup.cnf, which sets the cluster address to "empty", which initializes a new cluster.
* <code>cap STAGE deploy HOSTFILTER=primary.nodes.hostname</code> - You need to deploy again to the primary node (the one you have <code>:primary => true</code> on in your stage's deploy file) so it can create the required users.  As long as the users get created and it says MySQL started correctly, you can go on to the next step.
* <code>cap STAGE mariadb:setup_slaves</code> - This uploads slave_setup.cnf and starts the slave, which, assuming your iptables rules are correct and the user was created correctly, will start MySQL on the slaves and kick off replication.
* <code>cap stage mariadb:status</code> - You need to run until all three nodes say they're synced.  If you have a lot of data, this could take a while.
* <code>cap stage mariadb:finalize_cluster</code> - This removes the two setup config files and restarts MySQL on all three servers - restarting the master first and then the slaves.

## Other Useful Cap Tasks

* <code>mariadb:status</code> - Tells you if all three nodes are synced.
* <code>mariadb:restart</code> - Safely restarts MySQL on all the nodes. You *never* want to restart all the nodes at once as MySQL won't come back up since there's not another node to talk to. If you change your configuration files and deploy, you'll need to remember to run this after the deploy finishes.

## Notes on Upgrading in Place

According to the MariaDB folks, it's possible to upgrade from MySQL 5.1 to MariaDB 5.x pretty much in place - and that's true, but it's not without its quirks, especially in a production deployment or moving from classic master/slave to a cluster.  

We're going to be upgrading some of our apps in the next week or two and will update the README with the steps we've taken and the configuration we end up running in production.

***

Unless otherwise specified, all content copyright &copy; 2014, [Rails Machine, LLC](http://railsmachine.com)
