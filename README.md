## Description

We consider this plugin **beta** at best.  We'll be making lots of updates to it over the next few weeks as we roll out MariaDB to several of our own apps.

This is a [Moonshine](http://github.com/railsmachine/moonshine) recipe for installing and configuring [MariaDB](http://mariadb.org), and setting up a Galera Cluster for replication and failover.  If there's only one server in the database_servers list, it will run MariaDB in standalone mode without any cluster configuration.  If there are two or more (3 nodes are recommended), then it will create the configuration for a cluster.  We've provided several cap tasks to properly configure and bootstrap the cluster (see the Bootstrapping the Cluster section)

## Gotchas and Warnings

* You should *never* restart all the nodes in your cluster at the same time, or you'll need to go through the setup cap tasks again.
* If you change any of the mariadb settings, you'll need to run the mariadb:restart task, as it's not restarted during deploy (for the reason stated above)
* We haven't tested this on a single server yet, just with a cluster.  There's no reason why it shouldn't work - but it might not.

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
    cluster_address.push server[:internal_ip]
  end
  
  allowed_hosts = internal_ips
  allowed_hosts.push 'localhost'
  
  servers_with_rails_env.each do |server|
    allowed_hosts.push server[:internal_ip]
  end
  
  {
    :gcomm_cluster_address => "gcomm://#{cluster_address.join(",")}",
    :wsrep_node_address => Facter.ipaddress_eth1,
    :wsrep_sst_receive_address => Facter.ipaddress_eth1,
    :wsrep_node_name => Facter.hostname,
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

* <code>mariadb:status</code> - Tells you if the nodes are synced.
* <code>mariadb:restart</code> - Safely restarts MySQL on all the nodes. You *never* want to restart all the nodes at once as MySQL won't come back up since there's not another node to talk to. If you change your configuration files and deploy, you'll need to remember to run this after the deploy finishes.

## Notes on Upgrading in Place

According to the MariaDB folks, it's possible to upgrade from MySQL 5.1 to MariaDB 5.x pretty much in place - and that's true, but it's not without its quirks, especially in a production deployment or moving from classic master/slave to a cluster.  

Thanks to a few days spent with [moonshine_vagrant](http://github.com/railsmachine/moonshine_vagrant), we now have a somewhat automated way to upgrade from MySQL 5.1 to MariaDB 5.5 using a series of cap tasks, deploys and a little manual intervention.  Before you get started, you should have something like this in your deploy stage (config/deploy/staging.rb, for example):

<pre><code>server 'mysql1.thing.com', :db, :master => true, :primary => true
server 'mysql2.thing.com', :db, :slave => true
server 'mysql3.thing.com', :db, :slave => true</code></pre>

Remember, MariaDB's cluster implementation works best with *three* database servers, though it will work with two.  We're also assuming you have classic MySQL replication in place - which we'll be turning off during the upgrade process (don't worry, MariaDB's replication is *way* better).  Here's the order you should do things in:

* Before changing your database manifest to use the MariaDB plugin, you should deploy one last time to make sure everything's up to date.
* Now add all the MariaDB stuff to your database manifest, *but don't deploy*!
* You should now put your app into maintenance mode and stop any workers you have (because MySQL's going down for at least a few minutes).
* Run <code>cap STAGE mariadb:remove_mysql</code>.  This stops slaving, shuts down MySQL and removes their packages.
* Now do a moonshine deploy *just* to the master.  It's going to fail in a couple of places, and that's OK.
* Once the deploy is finished, ssh to the master and do the following:
  * <code>sudo bash</code>
  * <code>mysqladmin shutdown</code>
  * <code>service mysql stop</code>
  * <code>ps -eaf | grep mysql</code> - If anything is in this list other than your ps command, kill -9 it.
  * <code>cd /var/lib/mysql</code>
  * <code>rm -f ib_logfile*</code>
  * <code>rm -f grastate.dat</code>
  * <code>rm -f galera.cache</code>
  * <code>service mysql start</code>
  * <code>mysql</code> and then run <code>show status like 'wsrep_%';</code>.  If you don't see the word "Synced" in there, then start over with the process from mysqladmin shutdown.  It sometimes takes a couple of restarts for mysql_upgrade to do its thing.
  * Once you get the right answer from the SQL query, you're ready to go on to the next steps.
* Do a moonshine deploy to just the slaves. For each one in turn, you'll need to go through the steps you went through on the master until the slaves show Synced (you should see the master's private IP address in there somewhere as well).
* Once they're synced, run <code>cap STAGE mariadb:finalize_cluster</code>, and as long as they're still synced at the end, you're done!





