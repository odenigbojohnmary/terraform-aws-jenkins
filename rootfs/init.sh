#!/usr/bin/env bash
[ -d /jenkins/plugins.d/ ] && \
  find /jenkins/plugins.d/ -type f -exec cat {} \; | \
  xargs /usr/local/bin/install-plugins.sh

[ -d /jenkins/jobs.d/ ] && \
  (ls  /jenkins/jobs.d | xargs -I {} mkdir -p /var/jenkins_home/jobs/{})  && \
  (ls  /jenkins/jobs.d | xargs -I {} cp -n /jenkins/jobs.d/{} /var/jenkins_home/jobs/{}/config.xml)

exec /usr/local/bin/jenkins.sh "$*"
