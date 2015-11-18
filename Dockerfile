FROM ubuntu:14.04
MAINTAINER MIT

#Get important package for relational-spreadsheets project
RUN apt-get update && apt-get install -y curl git

RUN git clone https://bitbucket.org/corwin0amber/relational-spreadsheets.git
#Use relational-spreadsheets folder
WORKDIR /relational-spreadsheets

RUN curl https://install.meteor.com/ | sh

EXPOSE 3000

#You can run docker image by youself!!
