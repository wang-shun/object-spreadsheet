![MIT CSAIL](https://www.csail.mit.edu/sites/default/files/logo.jpg)

# Object Spreadsheets

Object Spreadsheets is an enhanced spreadsheet tool with support for storing and manipulating structured data. End-user developers can use it to work directly with a data set or to build a web application that offers constrained view and update access to a larger population of users.

This is a research prototype and we do not recommend relying on it for anything important at this point.

[Project web site](http://sdg.csail.mit.edu/projects/objsheets/)

## Running

### Linux and Mac OS X

```
# Install git as per the instructions on https://git-scm.com/.
curl https://install.meteor.com/ | sh
git clone --recursive https://bitbucket.org/objsheets/objsheets
cd objsheets
meteor
# Open http://localhost:3000/ in your browser.
```

### Windows

* [Install Git](https://git-scm.com/downloads) and choose "Use Git from the Windows Command Prompt".
* [Install Meteor](https://www.meteor.com/install).
* Using the Windows command prompt (cmd):

        git clone --recursive https://bitbucket.org/objsheets/objsheets
        cd objsheets
        meteor

* Open http://localhost:3000/ in your browser.

(This is not the only way to do it, but it's one that we've tested.)

### Supported browsers

We try to support recent versions of Firefox and Google Chrome.

## Docker Image
You can build docker image by yourself or Pull from docker hub

    
        #docker pull edwarddoong/objsheet
        #docker run -d -p 3000:3000 $(YOUR_IMAGE_ID) meteor run

## How to Check it?

You can use [umongo](https://github.com/agirbal/umongo) to check your mongoDB.

## Developing

See [DEVELOPMENT.md](DEVELOPMENT.md).
