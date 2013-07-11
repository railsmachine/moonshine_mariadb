set :mariadb_servers do
  find_servers(:roles => :db)
end

set :mariadb_initial_master do 
  find_servers(:roles => :db, :only => {:primary => true}).first
end

set :mariadb_initial_slaves do 
  find_servers(:roles => :db, :except => {:primary => true})
end

namespace :mariadb do
  
  desc "Performs initial steps for getting the new master ready to form a new cluster."
  task :setup_master, :roles => :db do
    transaction do
      make_slave_setup_conf
      upload_master_setup_conf
      restart_master
    end
    puts "You now need to do a moonshine deploy just to #{mariadb_initial_master} to create all the database users you need."
  end
  
  desc "Adds the initial slaves to the cluster."
  task :setup_slaves, :roles => :db do
    transaction do
      upload_slave_setup_conf
      restart_slaves
      sleep 5
      upload_debian_cnf_to_slaves
    end
    status
    puts "Now run cap #{stage} mariadb:status until all nodes are synced, and then run cap #{stage} mariadb:finalize_cluster to perform cleanup."
  end
  
  desc "Finalize cluster setup."
  task :finalize_cluster, :roles => :db do
    transaction do
      remove_master_setup_conf
      remove_slave_setup_conf
      restart_master
      sleep 3
      restart_slaves
      sleep 3
      status
    end
    puts "As long as all the nodes say they're synced, you're done!"
  end

  task :upload_master_setup_conf, :roles => :db do
    # TODO: Download the debian.cnf from the master.
    debian_conf = capture "sudo cat /etc/mysql/debian.cnf", :hosts => mariadb_initial_master
    f = File.open("debian.cnf",'w+')
    f.puts debian_conf
    f.close 
    
    # TODO: Upload new master_setup.cnf to initial master in /src/mysql/conf.d/ that sets the wsrep_cluster_address to gcomm://
    upload 'app/manifests/templates/master_setup.cnf', '/tmp/master_setup.cnf', :hosts => mariadb_initial_master
    sudo 'mv /tmp/master_setup.cnf /etc/mysql/conf.d/master_setup.cnf', :hosts => mariadb_initial_master
  end

  task :make_slave_setup_conf, :roles => :db do
    set :mariadb_initial_master_address do
      capture 'facter ipaddress_eth1', :hosts => mariadb_initial_master
    end
    
    f = File.open("slave_setup.cnf",'w+')
    f.puts <<-eos
    [mysqld]
    
    wsrep_cluster_address = gcomm://#{mariadb_initial_master_address}
    eos
    f.close
  end
  
  task :upload_slave_setup_conf, :roles => :db do
    upload "slave_setup.cnf", "/tmp/slave_setup.cnf", :hosts => mariadb_initial_slaves
    sudo 'mv /tmp/slave_setup.cnf /etc/mysql/conf.d/slave_setup.cnf', :hosts => mariadb_initial_slaves
  end

  task :restart_master, :roles => :db do
    sudo 'service mysql restart', :hosts => mariadb_initial_master
  end

  task :restart_slaves, :roles => :db do
    sudo 'service mysql restart', :hosts => mariadb_initial_slaves
  end

  task :upload_debian_cnf_to_slaves, :roles => :db do
    sudo 'cp /etc/mysql/debian.cnf /etc/mysql/debian.cnf.orig', :hosts => mariadb_initial_slaves
    upload 'debian.cnf', '/tmp/debian.cnf', :hosts => mariadb_initial_slaves
    sudo 'mv /tmp/debian.cnf /etc/mysql/debian.cnf', :hosts => mariadb_initial_slaves
  end

  task :remove_master_setup_conf, :roles => :db do
    sudo 'rm -f /etc/mysql/conf.d/master_setup.cnf', :hosts => mariadb_initial_master
  end
  
  task :remove_slave_setup_conf, :roles => :db do
    sudo 'rm -f /etc/mysql/conf.d/slave_setup.cnf', :hosts => mariadb_initial_slaves
  end

  task :status, :roles => :db do
    sudo "/usr/bin/mysql -u root -e \"show status like 'wsrep_local_state_comment';\""
    sudo "/usr/bin/mysql -u root -e \"show status like 'wsrep_incoming_addresses';\""
  end
  
  task :restart, :roles => :db do
    transaction do
      sudo 'service mysql restart', :hosts => mariadb_initial_slaves
      sleep 5
      sudo 'service mysql restart', :hosts => mariadb_initial_master
    end
  end

end
