


### This is an example charts repository.

How It Works

Create github repository and create docs folder in root directory.

The docs folder contains index.html file

set up GitHub Pages to point to the docs folder.

From there, I can create and publish docs like this:

$ helm create hlf-ca
$ cd hlf-ca ; helm dependency update ; cd -
$ helm package hlf-ca
$ mv hlf-ca-0.1.0.tgz docs
$ helm repo index docs --url https://akhilrajmailbox.github.io/Hyperledger-Fabric/docs
$ git add .
$ git commit -m "updated" -av
$ git push origin master

add helm repo to your system and install.

helm repo add ar-repo https://akhilrajmailbox.github.io/Hyperledger-Fabric/docs
