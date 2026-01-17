FROM container-registry.oracle.com/middleware/weblogic:14.1.2.0-generic-jdk17-ol8

USER oracle

#COPY source/helloworld.war /u01/oracle/user_projects/domains/mydomain/autodeploy/
COPY source/helloworld.war /u01/oracle/user_projects/domains/base_domain/autodeploy/