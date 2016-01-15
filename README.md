![MIT](https://www.csail.mit.edu/sites/default/files/logo.jpg)

# Object Spreadsheets #

Object Spreadsheets (formerly Relational Spreadsheets) is an end-user development tool for web applications backed by entity-relationship data.  It combines the richly interactive all-in-one interface of a spreadsheet with a more powerful data model, seeking to make it as easy as possible for end-user developers to build the custom logic they need to automate business processes of low to medium complexity.

This is a research prototype and we do not recommend relying on it for anything important at this point.

[Project web site](http://sdg.csail.mit.edu/projects/objsheets/)

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
You can build docker image by yourself or Pull from docker hub

    
        #docker pull edwarddoong/objsheet
        #docker run -d -p 3000:3000 $(YOUR_IMAGE_ID) meteor run

### How to Check it? ###

You can use browser(http://localhost:3000) to access the default web page setting.

You can use umongo to check your mongoDB.
