

# 0 准备

## 0.1 开启IPv4 IP forward

编辑/etc/sysctl.conf，添加或修改：

```
net.ipv4.ip_forward=1
```

然后重启网络和docker。

```
systemctl restart network
systemctl restart docker
```

## 0.2 挂载目录的SELinux权限

如果有挂载目录，需要配置SELinux权限。如挂载主机目录为`/srv/mysql`，则：

```
chcon -Rt svirt_sandbox_file_t /srv/mysql
```

## 0.3 下载docker-compose

参考[文档](https://docs.docker.com/compose/install/).

```
sudo curl -L https://github.com/docker/compose/releases/download/1.21.2/docker-compose-$(uname -s)-$(uname -m) -o /usr/local/bin/docker-compose
sudo chmod +x /usr/local/bin/docker-compose
```

## 0.4 加独立虚拟磁盘

虚拟机模板的根目录并不大，因此通常需要将容器的数据部分通过volume的方式共享到主机新增的独立磁盘上。

```
mkfs.xfs /dev/sdb; echo -e "/dev/sdb\t/srv\txfs\tdefaults\t0 0" >> /etc/fstab; mount -a
```

## 0.5 防火墙方面

**iptables增加端口**

配置iptable规则：`vi /etc/sysconfig/iptables`

```
# 增加一行（如增加UDP 123端口）
-A INPUT -m state --state NEW -m udp -p udp --dport 123 -j ACCEPT
```

**firewalld开通端口**

```
firewall-cmd --zone=public --add-port=80/tcp --permanent
systemctl restart firewalld
```

# 1 部署节点


## 1.1 Infra-tools


Infra-tools主要包括NTP、DNS等，docker-compose.yml如下：


```
version: '3'

services:
  dns:
    image: andyshinn/dnsmasq
    container_name: dns
    privileged: true
    cap_add:
      - NET_ADMIN
    ports:
      - "53:53"
      - "53:53/udp"
    volumes:
      - './etc_dnsmasq.conf:/etc/dnsmasq.conf:rw'
      - './etc_resolv.dnsmasq:/etc/resolv.dnsmasq:rw'
      - './etc_dnsmasq.hosts:/etc/dnsmasq.hosts:rw'
```


容器的三个配置文件通过volume的方式与主机当前目录下的配置文件共享。


DNS服务使用的是dnsmasq。其中，


* `/etc/dnsmasq.conf`是主配置文件，主要内容有两行：


```
# 指定配置外网DNS地址的resolv文件
resolv-file=/etc/resolv.dnsmasq
# 指定配置内网域名解析关系的文件
addn-hosts=/etc/dnsmasq.hosts
```


* `/etc/resolv.dnsmasq`，配置外网DNS地址，内容如下：


```
nameserver 114.114.114.114
nameserver 202.106.0.20
```


* `/etc/dnsmasq.hosts`，配置内网域名解析，内容如下：


```
# ops
172.31.0.254    dns ntp dns.trustchain.com ntp.trustchain.com
172.31.0.253    nas nas.trustchain.com
172.31.3.101    vcenter vcenter.trustchain.com


172.23.0.100    ldap ldap.trustchain.com
172.23.0.101    jira jira.trustchain.com


... ...
```


## 1.2 LDAP


LDAP使用OpenLDAP进行维护，使用phpldapadmin管理界面。docker-compose.yml如下：


```
version: '3'

services:
  ldap:
    image: osixia/openldap
    container_name: ldap
    ports:
      - "389:389"
      - "636:636"
    environment:
      - LDAP_ORGANISATION=TrustChainTech        # 1
      - LDAP_DOMAIN=trustchain.com              # 1
      - LDAP_ADMIN_PASSWORD=admin               # 1
    volumes:
      - /srv/ldap/var:/var/lib/ldap             # 2
      - /srv/ldap/etc:/etc/ldap/slapd.d         # 2

  ldap-admin:
    image: osixia/phpldapadmin
    container_name: ldap-admin
    ports:
      - "443:443"
    environment:
      - PHPLDAPADMIN_LDAP_HOSTS=ldap
```


1. 默认的LDAP组织是`example.org`，可以通过参数指定初始化的组织及管理员密码，管理员账号是`admin`；
2. OpenLDAP需要保存的数据主要是`/etc`下的配置和`/var`下的数据。




## 1.3 JIRA


docker-compose.yml如下：


```
version: '3'

services:
  mysql:
    image: mysql:5.7
    container_name: mysql
    environment:
      - MYSQL_ROOT_PASSWORD=root
      - MYSQL_DATABASE=jiradb
      - MYSQL_USER=jira
      - MYSQL_PASSWORD=jira
    volumes:
      - /srv/mysql:/var/lib/mysql                                                # 1
    command: ["--character-set-server=utf8", "--collation-server=utf8_bin"]      # 2

  jira:
    image: blacklabelops/jira:7.8.1
    privileged: true
    container_name: jira
    depends_on:
      - mysql
    ports:
      - "80:8080"
    user: 0:0                                                                     # 3
    environment:
      - DOCKER_WAIT_HOST=mysql                                                    # 4
      - DOCKER_WAIT_PORT=3306                                                     # 4
      - JIRA_DATABASE_URL=mysql://jira@mysql/jiradb
      - JIRA_DB_PASSWORD=jira
      - "CATALINA_OPTS= -Xms2g -Xmx6g"                                            # 5
    volumes:
      - /srv/jira:/var/atlassian/jira                                             # 1
```


1. 将容器内数据挂载到`/srv`下；
2. JIRA要求数据库charset为`utf8`；
3. 使用root账号，否则JIRA中部分功能会因账号权限问题不可用；
4. 等待MySQL服务可用后再启动JIRA；
5. JIRA默认为JVM分配的内存非常低，通过参数指定。


> 一个docker-compose配置文件中的多个Service是共享网络的，可以通过`network`指定，否则会默认创建一个`<文件夹名>_default`的bridge网络。
服务间可以通过服务名进行通讯，如JIRA容器中ping mysql是OK的。


## 1.3 Confluence


docker-compose.yml如下：


```
version: '3'

services:
  mysql:
    image: mysql:5.7
    container_name: mysql
    environment:
      - MYSQL_ROOT_PASSWORD=root
      - MYSQL_DATABASE=confluencedb
      - MYSQL_USER=confluence
      - MYSQL_PASSWORD=confluence
    volumes:
      - /srv/mysql:/var/lib/mysql
    command: ["--character-set-server=utf8", "--collation-server=utf8_bin", "--default-storage-engine=INNODB", "--max_allowed_packet=256M", "--innodb_log_file_size=2GB", "--binlog_format=row", "--transaction-isolation=READ-COMMITTED"]   # 1

  confluence:
    image: blacklabelops/confluence:6.8.2
    privileged: true
    container_name: confluence
    depends_on:
      - mysql
    ports:
      - "80:8090"
      - "8091:8091"
    user: 0:0
    environment:
      - DOCKER_WAIT_HOST=mysql
      - DOCKER_WAIT_PORT=3306
      - CATALINA_PARAMETER1=-Xms                                                # 2
      - CATALINA_PARAMETER_VALUE1=2g                                            # 2
      - CATALINA_PARAMETER1=-Xmx                                                # 2
      - CATALINA_PARAMETER_VALUE1=4g                                            # 2
    volumes:
      - /srv/confluence:/var/atlassian/confluence
```


1. Confluence对数据库的要求，通过MySQL提供的参数可以指定；
2. 配置为JVM分配的内存。


## 1.4 Gerrit


### 1.4.1 docker-compose.yml及相关配置文件


gerrit使用官方Docker镜像，使用postgres作为数据库。docker-compose.yml如下：


```
version: '3'

services:
  gerrit:
    image: gerritcodereview/gerrit:2.14.8                                  # 1
    container_name: gerrit
    hostname: gerrit.trustchain.com
    privileged: true
    dns:
      - 172.31.0.254                                                       # 2
    ports:
      - "29418:29418"
      - "80:8080"
    depends_on:
      - postgres
    volumes:
     - /srv/gerrit/etc:/var/gerrit/etc
     - /srv/gerrit/git:/var/gerrit/git
     - /srv/gerrit/index:/var/gerrit/index
     - /srv/gerrit/cache:/var/gerrit/cache
    #entrypoint: java -jar /var/gerrit/bin/gerrit.war init -d /var/gerrit  # 4

  postgres:
    image: postgres:9.6
    container_name: postgres
    environment:
      - POSTGRES_USER=gerrit                                                # 3
      - POSTGRES_PASSWORD=gerrit                                            # 3
      - POSTGRES_DB=reviewdb                                                # 3
    volumes:
      - /srv/postgres:/var/lib/postgresql/data
```


1. gerrit比较新的2.15版存在重启会刷掉gerrit主配置文件中canonicalWebUrl的问题，暂时使用2.14.8版本；
2. 指定DNS，因为Gerrit要通过域名连接ldap；
3. 启动postgresql的时候创建`gerrit`用户，并创建`reviewdb`数据库。
4. 初始化命令，后边会介绍到。


Gerrit要连接OpenLDAP，因此需要在启动前将配置文件提供出来。


`/etc/gerrit.config`是Gerrit的主配置文件，定义了数据库、LDAP等配置，对应主机的`/srv/gerrit/etc/gerrit.config`：


```
[gerrit]
        basePath = git
        canonicalWebUrl = http://gerrit.trustchain.com

[database]
        type = postgresql
        hostname = postgres
        database = reviewdb
        username = gerrit

[index]
        type = LUCENE

[auth]
        type = ldap
        gitBasicAuth = true

[ldap]
        server = ldap://ldap.trustchain.com
        username = cn=admin,dc=trustchain,dc=com
        accountBase = dc=trustchain,dc=com
        accountPattern = (&(objectClass=person)(uid=${username}))
        accountFullName = displayName
        accountEmailAddress = mail

[sshd]
        listenAddress = *:29418

[httpd]
        listenUrl = http://*:8080/

[cache]
        directory = cache

[container]
        user = root
```


`/etc/secure.config`对应主机的`/srv/gerrit/etc/secure.config`，用于单独配置数据库和LDAP的密码：


```
[database]
        password = gerrit

[ldap]
        password = admin
```

### 1.4.2 启动过程


1. Gerrit容器使用ID为1000的`gerrit`用户，因此首先确保主机存在该用户（主要用于volume权限）。
2. 创建目录`mkdir -p /srv/gerrit/{etc,git,index,cache}`，并将上述两个配置文件拷到`/srv/gerrit/etc`下，并配置权限给`gerrit`用户：`chown gerrit:gerrit -R /srv/gerrit`。
3. 启动postgresql：`docker-compose up -d postgres`，可以通过`docker logs -f postgres`观察日志，出现`database system is ready to accept connections`时表示启动完毕。
4. gerrit第一次启动时需要初始化review-site（即本例中的`/var/gerrit`），取消掉docker-compose.yml中的注释，然后运行`docker-compose up gerrit`启动gerrit。
5. 初始化完成后，再把docker-compose.yml中初始化的那行注释掉，然后用后台方式启动gerrit即可：`docker-compose up -d gerrit`。


不过以上过程都做成了脚本，直接执行源码中的`newly-install.sh`脚本即可（注意：该脚本会清除数据，主要用于第一次部署）。



## 1.5 Gitlab

### 1.5.1 让出22端口

注意，由于gitlab的SSH默认使用的是22端口，因此主机的sshd建议修改为其他端口。编辑`/etc/ssh/sshd_config`增加2222端口：

```
#Port 22
Port 2222
```

然后执行如下命令为SELinux开启2222端口：

```
semanage port -a -t ssh_port_t -p tcp 2222
```

然后执行如下命令让防火墙通过2222端口：

```
firewall-cmd --permanent --add-port=2222/tcp
systemctl restart firewalld.service
```

### 1.5.2 启动gitlab

使用gitlab官方docker镜像，docker-compose.yml文件如下：

```
version: '3'

services:
  mysql:
    image: gitlab/gitlab-ce
    container_name: gitlab
    hostname: gitlab
    privileged: true
    ports:
      - "22:22"
      - "80:80"
      - "443:443"
    volumes:
      - /srv/gitlab/config:/etc/gitlab      # 1
      - /srv/gitlab/logs:/var/log/gitlab    # 1
      - /srv/gitlab/data:/var/opt/gitlab    # 1
```

1. 挂载目录如下：

| 主机目录 | 容器目录 | 内容 |
| --- | --- | --- | --- |
| /srv/gitlab/data | /var/opt/gitlab | 应用数据 |
| /srv/gitlab/logs | /var/log/gitlab | 日志 |
| /srv/gitlab/config | /etc/gitlab | GitLab配置文件 | 

### 1.5.3 配置gitlab

由于配置文件已经共享到宿主机，因此可以通过编辑`/srv/gitlab/config/gitlab.rb`配置gitlab：

```
# 配置external_url，外部访问地址，比如每个git库的clone地址就是基于它拼出来的
external_url 'http://gitlab.trustchain.com'
# 配置LDAP
gitlab_rails['ldap_enabled'] = true

###! **remember to close this block with 'EOS' below**
gitlab_rails['ldap_servers'] = YAML.load <<-'EOS'
  main: # 'main' is the GitLab 'provider ID' of this LDAP server
    label: 'LDAP'
    host: 'ldap.trustchain.com'
    port: 389
    uid: 'cn'
    bind_dn: 'cn=admin,dc=trustchain,dc=com'
    password: 'Tcartn0ctram$'
    encryption: 'plain' # "start_tls" or "simple_tls" or "plain"
    verify_certificates: true
    active_directory: false
    allow_username_or_email_login: true
    lowercase_usernames: true
    block_auto_created_users: false
    base: 'dc=trustchain,dc=com'
    user_filter: ''
    ## EE only
    group_base: ''
    admin_group: ''
    sync_ssh_keys: false
EOS
```

然后执行如下命令使gitlab配置生效：

```
docker exec -it gitlab gitlab-ctl reconfigure
```
