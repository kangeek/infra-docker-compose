[TOC]

目前的方案主要是围绕Gitlab及其自带的gitlab-runner在搭建，如图。

![](https://tva1.sinaimg.cn/large/006tNbRwly1gaia7y8na7j31f60nijwo.jpg)

如果要查看基于Gerrit和Jenkins的部署方式，请切换到v0.1分支（其中各组件版本可能有点旧了，请自行使用镜像最新版本的镜像）。

以下工具基于 Docker & Docker Compose 来部署，其中的配置全部基于“example.com”，具体部署前可根据实际情况进行批量替换。

# 0 准备

## 0.1 安装docker

```
curl -fsSL https://get.docker.com | bash -s docker --mirror Aliyun
```

并根据需要配置国内源。

## 0.2 下载docker-compose

参考[文档](https://docs.docker.com/compose/install/).

```
sudo curl -L https://github.com/docker/compose/releases/download/1.21.2/docker-compose-$(uname -s)-$(uname -m) -o /usr/local/bin/docker-compose
sudo chmod +x /usr/local/bin/docker-compose
```

## 0.2 开启IPv4 IP forward（不配置似乎也没事，待验证）

容器要想访问外部网络，需要本地系统的转发支持。编辑`/etc/sysctl.conf`，添加或修改：

```
net.ipv4.ip_forward=1
```

然后重启网络和docker。

```
systemctl restart network
systemctl restart docker
```

## 0.4 挂载目录的SELinux权限

这一版，容器数据的持久化数据的挂载有限使用命名卷，而不是直接将主机目录挂载到容器里。以便避免权限等问题导致的坑。

如果开启SELinux，并且采用目录挂载挂载的方式，需要配置SELinux权限。如挂载主机目录为`/srv/mysql`，则执行：

```
chcon -Rt svirt_sandbox_file_t /srv/mysql
```

## 0.4 防火墙方面

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

## 1.1 研发内网域名解析

研发内用的DNS有dnsmasq来提供，由nginx进行反向代理。DNS的docker-compose.yml如下：

```
services:
  dns:
    image: andyshinn/dnsmasq
    container_name: dns
    hostname: dns
    networks:
      - devops
    privileged: true
    cap_add:
      - NET_ADMIN
    ports:
      - "53:53"
      - "53:53/udp"
    volumes:
      - './etc_dnsmasq.conf:/etc/dnsmasq.conf'
      - './etc_resolv.dnsmasq:/etc/resolv.dnsmasq'
      - './etc_dnsmasq.hosts:/etc/dnsmasq.hosts'
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
172.31.0.254    dns ntp dns.example.com ntp.example.com
172.31.0.253    nas nas.example.com
172.31.3.101    vcenter vcenter.example.com

172.23.0.100    ldap ldap.example.com
172.23.0.101    jira jira.example.com

... ...
```



## 1.2 反向代理

平台由多个组件构成，涉及多个不同的IP和端口号，为了方便记忆，采用域名+反向代理的配置方式。反向代理用Nginx提供，`docker-compose.yml`如下：

```
services:
  nginx:
    image: nginx
    container_name: nginx
    hostname: nginx
    networks:
      - devops
#   dns:
#     - 172.31.0.254
    privileged: true
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./conf.d:/etc/nginx/conf.d	# 1
      - ./www:/var/www							# 2
      - ./ssl:/etc/nginx/ssl				# 3
```

1. 所有的反向代理配置放在`conf.d`目录下，随着下面各个组件的介绍会继续补充；
2. 静态页面放在`www`目录下；
3. 证书放在`ssl`下。

## 1.3 LDAP

LDAP使用OpenLDAP进行维护，使用phpldapadmin管理界面。这一版的LDAP增加了SSL支持，因此需要提供证书。docker-compose.yml如下：

```
services:
  ldap:
    image: osixia/openldap
    container_name: ldap
    hostname: ldap
    networks:
      - devops
    ports:
      - "389:389"
      - "636:636"
    environment:
      - LDAP_ORGANISATION=ExampleCom
      - LDAP_DOMAIN=example.com
      - LDAP_ADMIN_PASSWORD=passwd
      - LDAP_READONLY_USER=true
      - LDAP_READONLY_USER_USERNAME=readonly
      - LDAP_READONLY_USER_PASSWORD=passwd
      - LDAP_TLS_CRT_FILENAME=ldap.example.com.crt		#1
      - LDAP_TLS_KEY_FILENAME=ldap.example.com.key		#1
      - LDAP_TLS_CA_CRT_FILENAME=root.example.com.crt	#1
    volumes:
      - ./ssl:/container/service/slapd/assets/certs		#1
      - ldap-var:/var/lib/ldap
      - ldap-etc:/etc/ldap/slapd.d
    logging:
      driver: "json-file"
      options:
        max-size: "200k"
        max-file: "10"

  ldap-admin:
    image: osixia/phpldapadmin
    container_name: ldap-admin
    hostname: ldap-admin
    depends_on:
      - ldap
    networks:
      - devops
#   If nginx not on the same "devops" network, uncomment the following two lines.
#   ports:
#     - "8080:80"
#     - "8443:443"
    environment:
      - PHPLDAPADMIN_LDAP_HOSTS=ldap
      - PHPLDAPADMIN_HTTPS_CRT_FILENAME=ldap.example.com.crt				#1
      - PHPLDAPADMIN_HTTPS_KEY_FILENAME=ldap.example.com.key				#1
      - PHPLDAPADMIN_HTTPS_CA_CRT_FILENAME=root.example.com.crt			#1
    volumes:
      - ./ssl:/container/service/phpldapadmin/assets/apache2/certs	#1
      - ldap-admin:/var/www/phpldapadmin
    logging:
      driver: "json-file"
      options:
        max-size: "200k"
        max-file: "10"
```

1. 证书文件通过卷挂载，并使用环境变量进行指定。

## 1.4 JIRA & Confluence

以Jira为例，docker-compose.yml如下：

```
version: '3'

services:
  mysql-jira:
    image: mysql:5.7
    container_name: mysql-jira
    environment:
      - MYSQL_ROOT_PASSWORD=devops
      - MYSQL_DATABASE=jiradb				#1
      - MYSQL_USER=jira							#1
      - MYSQL_PASSWORD=devops				#1
    networks:
      - devops
    volumes:
      - ./mysql/mysqld_jira.cnf:/etc/mysql/conf.d/mysqld_jira.cnf		#3
      - mysql-jira:/var/lib/mysql
    logging:
      driver: "json-file"
      options:
        max-size: "200k"
        max-file: "10"
  jira:
    image: atlassian/jira-software
    container_name: jira
    hostname: jira
    depends_on:
      - mysql-jira
    ports:
      - "8081:8080"
    environment:
      - JVM_MINIMUM_MEMORY=512m
      - JVM_MAXIMUM_MEMORY=2048m
      - ATL_PROXY_NAME=jira.example.com #2
      - ATL_PROXY_PORT=443							#2
      - ATL_TOMCAT_SCHEME=https					#2
      - ATL_TOMCAT_SECURE=true					#2
    networks:
      - devops
    volumes:
      - ./mysql/mysql-connector-java-5.1.48.jar:/opt/atlassian/jira/lib/mysql-connector-java-5.1.48.jar																#3
      - jira:/var/atlassian/application-data/jira
```

1. 启动MySQL的时候即初始化好数据库和用户；
2. Jira前方经过反向代理，而反向代理配置了SSL；
3. Jira对数据库有编码的要求，`./mysql/mysqld_jira.cnf`中可见：

```
[client]
default-character-set = utf8mb4

[mysql]
default-character-set = utf8mb4

[mysqld]
character-set-client-handshake = FALSE
character-set-server = utf8mb4
collation-server = utf8mb4_bin
```

> [Jira和Confluence的破解方法](https://blog.csdn.net/get_set/article/details/80856922)，仅用于学习，企业用户请购买正版。

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
services:
  gitlab:
    image: gitlab/gitlab-ce
    container_name: gitlab
    hostname: gitlab
    environment:
      GITLAB_OMNIBUS_CONFIG: |
        external_url 'https://gitlab.example.com'	#1
        nginx['redirect_http_to_https'] = true		#1
    ports:
      - "2222:22"
      - "8080:80"
      - "8443:443"
    networks:
      - devops
    volumes:
      - gitlab-config:/etc/gitlab								#2
      - gitlab-logs:/var/log/gitlab							#2
      - gitlab-data:/var/opt/gitlab							#2
    logging:
      driver: "json-file"
      options:
        max-size: "200k"
        max-file: "10"

```

1. 由于gitlab前方有支持SSL的反向代理，external_url为用户使用的地址；此处`GITLAB_OMNIBUS_CONFIG`环境变量可用于提前给出任意`gitlab.rb`中的配置。

挂载目录如下：

| 主机目录 | 容器目录 | 内容 |
| --- | --- | --- |
| gitlab-data | /var/opt/gitlab | 应用数据 |
| gitlab-logs | /var/log/gitlab | 日志 |
| gitlab-config | /etc/gitlab | GitLab配置文件 |

### 1.5.3 gitlab与LDAP的集成

由于配置文件已经共享到宿主机，因此可以通过编辑`gitlab-config`卷中的`gitlab.rb`配置gitlab：

```
###! **remember to close this block with 'EOS' below**
gitlab_rails['ldap_servers'] = YAML.load <<-'EOS'
  main: # 'main' is the GitLab 'provider ID' of this LDAP server
    label: 'LDAP'
    host: 'ldap.example.com'
    port: 389
    uid: 'cn'
    bind_dn: 'cn=admin,dc=example,dc=com'
    password: '<passwd of admin>'
    encryption: 'plain' # "start_tls" or "simple_tls" or "plain"
    verify_certificates: true
    active_directory: false
    allow_username_or_email_login: true
    lowercase_usernames: true
    block_auto_created_users: false
    base: 'dc=example,dc=com'
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

## 1.6 SonarQube

Sonarqube没有太多可解释的，与Jira或Confluence类似，就是典型的一个数据库+一个应用的部署方式，数据库启动时自动创建database和相应的用户的密码；SonarQube为官方镜像。

SonarQube中用到的插件可以到[SonarQube插件库](https://docs.sonarqube.org/display/PLUG/Plugin+Library)下载，并复制到`sonar-extensions`卷的`plugins`目录下，并重启使其生效。

## 1.7 Nexus

仍然采用容器的部署方式，采用官方镜像`sonatype/nexus3`。

使用`nginx`进行反向代理，将不同的域名映射到不同的nexus端口或路径。

因此`docker-compose.yml`文件内容如下：

```
services:
  nexus:
    image: sonatype/nexus3
    container_name: nexus
    hostname: nexus
    networks:
      - devops
    ports:
      - "8081:8081"
    volumes:
     - nexus-data:/nexus-data

  registry:
    image: registry:2
    container_name: registry
    networks:
      - devops
    ports:
      - 5000:5000
    environment:
      - REGISTRY_PROXY_REMOTEURL="https://docker.mirrors.ustc.edu.cn"
    volumes:
      - registry:/var/lib/registry
```

## 1.8 上网代理

由于研发人员经常需要上Google，或查询各种技术官网资料，因此一个统一的上网代理还是有必要的。

这里使用SOCKS5来做外网的代理，支持PAC模式和全局代理模式。

1. 代理使用sslocal，代理服务器的配置通过json文件传给该命令，端口为1080；
2. sslocal的代理为socks协议，因此使用privoxy转为http协议，端口为8118，该代理地址可用于全局代理模式的配置；
3. PAC代理模式维护一个list，只有list中的网址是走代理的，通过一个pac文件来维护，同时指定了SOCKS代理的地址，将该pac文件用http服务提供出来，使用者直接配置该pac文件的http地址即可使用PAC方式上网。

以上，第1,2由`sgrio/alpine-sslocalproxy`容器提供；第3条就起一个`httpd`容器，将pac文件用http访问即可。docker-compose.yml如下：

```
services:
  proxy:
    image: sgrio/alpine-sslocalproxy
    container_name: proxy
    hostname: proxy
    networks:
      - devops
    privileged: true
    ports:
      - "1080:1080"
      - "8118:8118"
    volumes:
      - './ss-client.json:/etc/shadowsocks-libev/config.json'    # 1
```

1. 代理服务器的配置通过volume挂载[`ss-client.json`]()文件实现。

### PAC的支持

pac的内容放在`nginx/www/pac`中通过挂载到nginx的目录下，从而可以直接通过地址`proxy.example.com/pac`访问。

pac的生成通过[`gen-pac.sh`](http://gitlab.example.com/infra/infra-docker-compose/blob/master/infra/gen-pac.sh)命令生成，该命令会从`gfwlist`拉取一份常用的代理网站地址list，另外还会加上`whitelist`中自定义的list，生成pac文件`index.html`。

> 代码中的代理配置信息（`infra/ss-client.json`）无效。

## 