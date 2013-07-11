module Moonshine
  module MariaDb
    
    def mariadb
      recipe :mariadb_package
      recipe :mariadb_config
      recipe :mariadb_service
      recipe :mariadb_user
      recipe :mariadb_database
      recipe :mariadbchk
      recipe :mysql_gem
    end

    def mariadb_package
      package 'python-software-properties',
        :ensure => :installed

      exec "add mariadb key",
        :command => "sudo apt-key adv --recv-keys --keyserver keyserver.ubuntu.com 0xcbcb082a1bb943db",
        :require => package('python-software-properties')

      exec "add mariadb repo",
        :command => "sudo add-apt-repository 'deb http://ftp.osuosl.org/pub/mariadb/repo/5.5/ubuntu lucid main'",
        :require => exec('add mariadb key')

      package 'mariadb-galera-server',
        :ensure => :installed,
        :require => [exec('apt-get update'),exec('add mariadb repo')]

      package 'galera',
        :ensure => :installed,
        :require => [exec('apt-get update'),exec('add mariadb repo')]
        
      package 'mysql-server',
        :ensure => :absent,
        :before => package('mariadb-galera-server')
    end

    def mariadb_config

      file '/etc/mysql/conf.d/mariadb.cnf',
        :content => template(File.join(File.dirname(__FILE__), '..', '..', 'templates', 'mariadb.cnf.erb')),
        :ensure => :present,
        :require => package('mariadb-galera-server')

      file '/etc/mysql/conf.d/moonshine.cnf',
        :content => template(File.join(File.dirname(__FILE__), '..', '..', 'templates', 'moonshine.cnf.erb')),
        :ensure => :present,
        :require => package('mariadb-galera-server')

    end

    def mariadb_user
      configuration[:mariadb][:allowed_hosts].each do |host|
        grant =<<EOF
GRANT ALL PRIVILEGES 
ON *.*
TO #{database_environment[:username]}@#{host}
IDENTIFIED BY \\"#{database_environment[:password]}\\";
FLUSH PRIVILEGES;
EOF

        exec "mariadb_sst_user_#{host}",
          :command => mysql_query(grant),
          :unless  => "mysql -u root -e ' select User from user where Host = \"#{host}\"' mysql | grep #{database_environment[:username]}",
          :require => service('mysql'),
          :before => exec('rake tasks')
          
      end
    end
    
    def mariadb_database
      exec "mysql_database",
        :command => mysql_query("create database #{database_environment[:database]};"),
        :unless => mysql_query("show create database #{database_environment[:database]};"),
        :require => service('mysql')
    end

    def mariadb_service

      service 'mysql', 
        :ensure => :running,
        :require => package('mariadb-galera-server')

    end

    def mariadbchk
      package 'xinetd', :ensure => :installed
      service 'xinetd', 
        :ensure => :running,
        :require => package('xinetd')


      file '/etc/xinetd.d/mariadbchk',
        :content => template(File.join(File.dirname(__FILE__), '..', '..', 'templates', 'mariadbchk.xinetd.erb')),
        :ensure => :present,
        :owner => 'root',
        :require => package('xinetd'),
        :notify => service('xinetd')

      file '/usr/bin/mariadbchk',
        :content => template(File.join(File.dirname(__FILE__), '..', '..', 'templates', 'mariadbchk.erb')),
        :ensure => :present,
        :owner => 'rails',
        :mode => '755',
        :require => package('xinetd'),
        :notify => service('xinetd')

    end
    
    private

      # Internal helper to shell out and run a query. Doesn't select a database.
      def mysql_query(sql)
        "su -c \'/usr/bin/mysql -u root -e \"#{sql}\"\'"
      end
    
  end
end