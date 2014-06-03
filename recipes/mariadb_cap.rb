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
  
  desc "WARNING: You only need to do this if you're upgrading from MySQL! Don't do this unless you're going to immediately deploy mariadb!! Stops slave on both databases, removes troublesome log files, and removes old mysql packages."
  task :remove_mysql, :roles => :db do
    stop_slave
    stop_mysql
    make_tmp_oldmysql
    move_bin_files
    remove_ib_logfiles
    move_relay_files
    remove_mysql_packages
    
    sleep 3

    download_debian_cnf
    make_slave_setup_conf
    upload_master_setup_conf
    
    upload_slave_setup_conf    
    
    
    puts "You now need to immediately moonshine deploy to the master (the first server in the mysql list)."
    puts "After you deploy, run cap STAGE mariadb:setup_master"
    puts "If you run into errors, then you'll need to ssh into each host and run sudo apt-get install -f"
    puts "Once you get the first server running, deploy to the slaves and run mariadb:setup_slaves"
    
  end
  
  task :mysql_upgrade_step_two, :roles => :db, :only => {:primary => true} do
    mysqladmin_shutdown
    sleep 2
    no_really_kill_mysql
    stop_mysql
    
    sleep 3
    
    remove_ib_logfiles
    remove_grastate
    remove_galera_cache

    start_mysql

    puts "You should now run mariadb:setup_master and then mariadb:setup_slaves"
  end
  
  task :no_really_kill_mysql, :roles => :db, :on_error => :continue do
    run 'sudo ps -ef | grep \'mysql\' | awk \'{print $2}\' | xargs kill -9'
  end
  
  task :start_master_mysql, :roles => :db, :on_error => :continue do
    sudo 'service mysql start', :hosts => mariadb_initial_master
  end
  
  task :start_slave_mysql, :roles => :db, :on_error => :continue do
    sudo 'service mysql start', :hosts => mariadb_initial_slaves
  end
  
  task :remove_grastate, :roles => :db, :on_error => :continue do
    sudo 'rm -f /var/lib/mysql/grastate.dat'
  end
  
  task :remove_galera_cache, :roles => :db, :on_error => :continue do
    sudo 'rm -f /var/lib/mysql/galera.cache'
  end
  
  task :step_two_move_debian_start, :roles => :db, :on_error => :continue do
    sudo "mv /etc/mysql/debian-start /etc/mysql/debian-start.old"
  end
  
  task :step_two_move_package_debian_start, :roles => :db, :on_error => :continue do
    sudo "cp /etc/mysql/debian-start.dpkg-dist /etc/mysql/debian-start"
  end
  
  task :mysqladmin_shutdown, :roles => :db, :on_error => :continue do
    sudo 'mysqladmin shutdown'
  end
  
  task :stop_slave, :roles => :db, :on_error => :continue do
    sudo 'mysql -e "stop slave\G"'
  end
  
  task :stop_mysql, :roles => :db, :on_error => :continue do
    sudo 'service mysql stop'
  end
  
  task :start_mysql, :roles => :db, :on_error => :continue do
    sudo 'service mysql start'
  end
  
  task :make_tmp_oldmysql, :roles => :db, :on_error => :continue do
    sudo 'mkdir -p /tmp/old_mysql'
  end
  
  task :move_bin_files, :roles => :db, :on_error => :continue do
    sudo 'mv /var/lib/mysql/*-bin.* /tmp/old_mysql'
  end
  
  task :remove_ib_logfiles, :roles => :db, :on_error => :continue do
    sudo 'rm -f /var/lib/mysql/ib_logfile*'
  end
  
  task :move_relay_files, :roles => :db, :on_error => :continue do
    sudo 'mv /var/lib/mysql/*-relay.* /tmp/old_mysql'
  end
  
  task :remove_mysql_packages, :roles => :db, :on_error => :continue do
    sudo 'apt-get remove mysql-server mysql-client -y'
  end
  
  desc "Performs initial steps for getting the new master ready to form a new cluster."
  task :setup_master, :roles => :db, :only => {:master => true} do
    transaction do
      download_debian_cnf
      make_slave_setup_conf
      upload_master_setup_conf
            
      restart_master
    end
    puts "You now need to do a moonshine deploy just to #{mariadb_initial_master} to create all the database users you need."
    puts "After that, deploy to all the slaves and run mariadb:setup_slaves."
  end
  
  desc "Adds the initial slaves to the cluster."
  task :setup_slaves, :roles => :db, :only => {:slave => true} do
    transaction do
      upload_slave_setup_conf
      restart_slaves
    end
    status
    puts "Now run cap #{stage} mariadb:status until all nodes are synced, and then run cap #{stage} mariadb:finalize_cluster to perform cleanup."
  end
  
  desc "Finalize cluster setup."
  task :finalize_cluster, :roles => :db do
    transaction do
      remove_master_setup_conf
      remove_slave_setup_conf
      upload_debian_cnf_to_slaves
      sleep 3
      status
    end
    puts "We've removed the setup config files. As long as things are synced, you're good to go!"
  end

  task :download_debian_cnf, :roles => :db do
    debian_conf = capture "sudo cat /etc/mysql/debian.cnf", :hosts => mariadb_initial_master
    f = File.open("debian.cnf",'w+')
    f.puts debian_conf
    f.close     
  end

  task :upload_master_setup_conf, :roles => :db do
    upload 'vendor/plugins/moonshine_mariadb/templates/master_setup.cnf', '/tmp/master_setup.cnf', :hosts => mariadb_initial_master
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
