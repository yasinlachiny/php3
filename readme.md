# Requirement
1. key<br />
At first, go to the EC2 section and create the key then store it in a safe place. This key is needed for accessing  EC2 VMs.

2. S3 role<br />
Storing cloud_user_accessKeys in EC2 VMs is not safe so I should give EC2 instances a role that can access S3. For simplicity, I give full access to S3.

3. cloud_user_accessKeys<br />
I want to update our code by Github so it should can access to our beanstalk by cloud_user_accessKeys.

# Create Application

1. go to the Elastic Beanstalk section.
3.choose proper application name
3.in Platform choose PHP 7.4 running on 64bit Amazon Linux 2
why this platform?
 Amazon Linux 2 use Nginx and PHP 7.3 have a bug in CICD.

4.upload your code as a zip file.
5.Select Configure more options

6.In Security Choose your EC2 key pair and IAM instance profile that you create in Requirement.
7.In Database write proper username and password
8.Select Create app
9.It takes a few minutes to show the final status
10. ssh to EC2 VMs and Import a SQL file into the created DB
```
    aws s3 cp BACKUP.sql s3://BUCKET_NAME
    mysql -u USER -h DATABASE-URL -p ebdb < BACKUP.sql 
    mysql -u USER -h DATABASE-URL -p -D ebdb -e "UPDATE users SET id=3 WHERE id=1;";                                    
```
#Data base username and password
We can not save username and password in plain text so we should use another way so in `config/database.php` I use 
```
define('RDS_HOSTNAME',$_SERVER['RDS_HOSTNAME']);
define('RDS_USERNAME',$_SERVER['RDS_USERNAME']);
define('RDS_PASSWORD',$_SERVER['RDS_PASSWORD']);
define('RDS_DB_NAME',$_SERVER['RDS_DB_NAME']);
```

# Nginx
Amazon Linux 1 (AL1) uses Apache2. However, Amazon Linux 2 (AL2) uses Nginx. After I use AL2 I get 404. 
so how can I solve that?
I should add bellow part to /etc/nginx/conf.d/elasticbeanstalk/php.conf
```
location / {
     try_files $uri $uri/ /index.php?$query_string;
         gzip_static on;
}
```
I can add this after the VMs is created but I want to do it automatically so 
I should create `.platform` and put the `php.conf` in `.platform/nginx/conf.d/elasticbeanstalk/php.conf`

# Copy .env from S3
I want to download .env from s3. in Create Application we assign S3fullaccess role to EC2. so we can run the S3 command without a secret key or access key.
so I create .ebextensions folder and  init.config file. In init.config I add 
```

container_commands:
    02_get_env_vars:
      command: aws s3 cp  s3://BUCKET-NAME/.env .
```
#install packages
We can install any packages by adding it to .ebextensions/init.config as bellow.
packages:
```
  yum:
    curl: []
    git: []
    htop: []
    php-common-7.4.5-1.amzn2.x86_64: []
    php-fpm-7.4.5-1.amzn2.x86_64: []
    php-mbstring-7.4.5-1.amzn2.x86_64: []
    php-xml-7.4.5-1.amzn2.x86_64: []
    php-mysqlnd-7.4.5-1.amzn2.x86_64: []
    php-bcmath-7.4.5-1.amzn2.x86_64: []
    php-json-7.4.5-1.amzn2.x86_64: []
```
`php-tokenizer` `php-curlphp-zip` have been install when we install  `php-common-7.4.5-1.amzn2.x86_64`

# composer install
first I install composer and then I install dependencies. so I add this block to init.config
```
container_commands:
    03-install-composer:
      command: "curl -sS https://getcomposer.org/installer | php"
    04-install-depenencies:
      command: "composer.phar install --optimize-autoloader"
```
# php artisan and permissions
for run php artisan I should add this code to init.config
```
container_commands:
    05-generate-key:
      command: "php artisan key:generate"
    06initdb:
        command: "php artisan migrate"
    07-link:
      command: "php artisan storage:link"
    08-add-permission:
      command: "sudo chmod -R ug+rwx storage bootstrap/cache"
```
I can not run `sudo chgrp -R www-data storage bootstrap/cache` because there is no `www-data` group.

# Setup a Supervisor
firs I should add bellow code to init.config
```
container_commands:
    01-copy_systemd_file:
      command: "easy_install supervisor"
    02-enable_systemd:
      command: "mkdir -p /etc/supervisor/conf.d"
    03-copy_laravel-worker_config:
      command: "cp .ebextensions/laravel-worker.conf /etc/supervisor/conf.d/laravel-worker.conf"
    04-copy_supervidor_config:
      command: "cp .ebextensions/supervisord.conf /etc/supervisord.conf"
    05-touch_log:
      command: "mkdir -p /var/log/supervisor/ && touch /var/log/supervisor/supervisord.log"
```
and create laravel-worker.conf in .ebextensions 
```[program:laravel-worker]
process_name=%(program_name)s_%(process_num)02d
command=php /var/www/html/artisan queue:work --tries=3
autostart=true
autorestart=true
user=root
numprocs=5
redirect_stderr=true
stdout_logfile=/var/www/html/storage/logs/worker.log
```
I can not run `/bin/supervisord -c /etc/supervisord.conf` by `container_commands` or `commands`
because I should run it after deployment. It has diffrent way in AL2 so be careful.
I should create `.platform/hooks/postdeploy` directory and add 01_Supervisor.sh file. and in 01_Supervisor.sh I can run  `/bin/supervisord -c /etc/supervisord.conf`
```
#!/usr/bin/env bash
touch /var/www/1.log
/bin/supervisord -c /etc/supervisord.conf
```
But after I launch this code I get permission denied error. so I should run `chmod +x .platform/hooks/postdeploy/01_Supervisor.sh`
and after that, the error disappears.


# Add a Cron entry
There are a lot of ways to do that but I do it by add bellow code to init.config
```
container_commands:
    01_remove_old_cron_jobs:
      command: "crontab -r || exit 0"
    02_cronjobs:
      command: "cat .ebextensions/crontab | crontab"
      leader_only: true
```
and add cron file to .ebextensions.
```
* * * * * php /var/www/medvoice/artisan schedule:run >> /dev/null 2>&1
```
 The important part is adding new empty line at the end of cron file.
# CI/CD
create `.github/workflows/` folder and add `php.yml`. in `php.yml` I can deploy a code and say what I want to do
for example I can create bellow part and get the timestamp and use it as  version_label(`version_label: "${{ steps.timestamp.outputs.date}}"`)
```
    - name: Get timestamp
      id: timestamp
      run: echo "::set-output name=date::$(date +'%Y-%m-%dT%H-%M-%S-%3NZ')"
```

![alt text](https://github.com/adam-p/markdown-here/raw/master/src/common/images/icon48.png "Logo Title Text 1")

