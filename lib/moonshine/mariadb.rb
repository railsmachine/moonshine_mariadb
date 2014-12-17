module Moonshine
  module MariaDb

    def mariadb
      recipe :mariadb_repo
      recipe :mariadb_package
      recipe :mariadb_config
      recipe :mariadb_service
      recipe :mariadb_user
      recipe :mariadb_database
      recipe :mariadbchk
      recipe :mariadb_logrotate
    end

    def mariadb_repo
      package 'python-software-properties',
        :ensure => :installed

      exec "add mariadb key",
        :command => "sudo apt-key adv --recv-keys --keyserver hkp://keyserver.ubuntu.com:80 0xcbcb082a1bb943db",
        :require => package('python-software-properties'),
        :unless => "sudo apt-key list | grep 'MariaDB Package Signing Key'"

      if ubuntu_precise?
        repo = "precise"
      else
        repo = 'lucid'
      end

      repo_path = "deb http://ftp.osuosl.org/pub/mariadb/repo/5.5/ubuntu #{repo} main"

      file '/etc/apt/preferences.d',
        :ensure => :directory

      file '/etc/apt/preferences.d/mariadb',
        :content => template(File.join(File.dirname(__FILE__), '..', '..', 'templates', "mariadb-preferences.erb")),
        :ensure => :present,
        :require => [file('/etc/apt/preferences.d')]

      exec "add mariadb repo",
        :command => "sudo add-apt-repository '#{repo_path}'",
        :require => exec('add mariadb key'),
        :unless => "cat /etc/apt/sources.list | grep '#{repo_path}'"

      exec "mariadb apt-get update",
        :command => "sudo apt-get update",
        :require => [exec('add mariadb repo'), file('/etc/apt/preferences.d/mariadb')]
    end

    def mariadb_package
      package 'mariadb-galera-server',
        :ensure => :installed,
        :require => [file('/etc/apt/preferences.d/mariadb'), exec('mariadb apt-get update'), exec('add mariadb repo')]

      package 'galera',
        :ensure => :installed,
        :require => [exec('mariadb apt-get update'), exec('add mariadb repo')]
    end

    def mariadb_config

      file '/etc/mysql/',
        :ensure => :directory

      file '/etc/mysql/conf.d',
        :ensure => :directory,
        :require => file('/etc/mysql')

      file '/etc/mysql/conf.d/mariadb.cnf',
        :content => template(File.join(File.dirname(__FILE__), '..', '..', 'templates', 'mariadb.cnf.erb')),
        :ensure => :present,
        :require => package('mariadb-galera-server')

      file '/etc/mysql/conf.d/moonshine.cnf',
        :content => template(File.join(File.dirname(__FILE__), '..', '..', 'templates', 'moonshine.cnf.erb')),
        :ensure => :present,
        :require => package('mariadb-galera-server')

      file '/etc/mysql/conf.d/innodb.cnf',
        :ensure => :absent

      file '/etc/mysql/debian-start',
        :ensure => :present,
        :content => template(File.join(File.dirname(__FILE__), '..', '..', 'templates', 'debian-start')),
        :owner => 'root',
        :mode => '0655',
        :require => [file('/etc/mysql'), package('mariadb-galera-server')]

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
          :unless  => "mysql -u root -e ' select User from user where Host = \"#{host}\" and User = \"#{database_environment[:username]}\"' mysql | grep #{database_environment[:username]}",
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
        :require => [package('mariadb-galera-server'),file('/etc/mysql/conf.d/mariadb.cnf'),file('/etc/mysql/conf.d/moonshine.cnf'),file('/etc/mysql/debian-start')]

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
        :owner => configuration[:user],
        :mode => '755',
        :require => package('xinetd'),
        :notify => service('xinetd')

    end

    def mariadb_logrotate
      file '/etc/logrotate.d/varlogmysql.conf', :ensure => :absent
      file '/etc/logrotate.d/mysql-server.conf', :ensure => :absent

      logrotate_options = configuration[:mariadb][:logrotate] || {}
      logrotate_options[:frequency] ||= 'daily'
      logrotate_options[:count] ||= '7'
      logrotate "/var/log/mysql/*.log",
        :logrotated_file => 'mariadb-server',
        :options => [
          logrotate_options[:frequency],
          'missingok',
          "rotate #{logrotate_options[:count]}",
          'compress',
          'delaycompress',
          'notifempty',
          'create 640 mysql adm',
          'sharedscripts'
        ],
        :postrotate => 'MYADMIN="/usr/bin/mysqladmin --defaults-file=/etc/mysql/debian.cnf"; if [ -z "`$MYADMIN ping 2>/dev/null`" ]; then if ps cax | grep -q mysqld; then exit 1; fi ; else $MYADMIN flush-logs; fi'
    end

    private

      # Internal helper to shell out and run a query. Doesn't select a database.
      def mysql_query(sql)
        "su -c \'/usr/bin/mysql -u root -e \"#{sql}\"\'"
      end

  end
end
