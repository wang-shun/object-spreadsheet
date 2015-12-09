![MIT](https://www.csail.mit.edu/sites/default/files/logo.jpg)

Note: The project is under development. It is not ready for deployment yet.

# Object Spread Sheets #

We're developing an application builder, based on a spreadsheet-like developer interface to an object-relational data model, to make it easier for non-programmers to build simple data-driven web applications.

### Dependencies Packages ###

* Curl (Linux System)
* [Meteor](https://www.meteor.com/)
* [Git](https://git-scm.com/)
* [Umongo](https://github.com/agirbal/umongo) (Option)

### Installing on Windows

* [Install Meteor Package](https://www.meteor.com/install)
* git clone $(Object Spread Sheets Git Link)
* Using Windoes Command Line windows (cmd)


    cd $(Local_Object_Spread_Sheets_PATH)

    meteor

### installing on Ubuntu 14.04 ###

    #git clone $(Object Spread Sheets Git Link)
    #curl https://install.meteor.com/ | sh
    #cd $(Local_Object_Spread_Sheets_PATH)
    #meteor

### Docker Image ###
You can build docker image by yourself.
or
Pull from docker hub
    #docker pull edwarddoong/objsheet
    #docker run -d -p 3000:3000 $(YOUR_IMAGE_ID) meteor run

### How to Check it? ###

You can use browser(http://localhost:3000) to access the default web page setting.

You can use umongo to check your mongoDB.
