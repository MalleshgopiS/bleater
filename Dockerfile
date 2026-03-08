FROM us-central1-docker.pkg.dev/bespokelabs/nebula-devops-registry/nebula-devops:1.0.0

ENV DISPLAY_NUM=1
ENV COMPUTER_HEIGHT_PX=768
ENV COMPUTER_WIDTH_PX=1024


USER root
WORKDIR /workspace

COPY setup.sh /setup.sh
RUN chmod +x /setup.sh

# Hide grader from agents
RUN mkdir -p /grader && chmod 700 /grader

ENV TASK_ROOT=/home/ubuntu/bleater-app