<picture>
  <source media="(prefers-color-scheme: dark)" srcset=".github/assets/banner-dark.png">
  <img src=".github/assets/banner.png" alt="JuiceFS" width="100%">
</picture>

<p align="center">
  <a href="https://github.com/junkerderprovinz/juicefs/actions/workflows/build.yml"><img src="https://img.shields.io/github/actions/workflow/status/junkerderprovinz/juicefs/build.yml?branch=main&label=Build&style=for-the-badge&logo=githubactions&logoColor=white" alt="Build" height="36"></a>&nbsp;
  <a href="https://github.com/juicedata/juicefs"><img src="https://img.shields.io/badge/Upstream-JuiceFS-3a7afe?style=for-the-badge&logo=go&logoColor=white" alt="Upstream JuiceFS" height="36"></a>&nbsp;
  <a href="https://unraid.net"><img src="https://img.shields.io/badge/Unraid-Template-f15a2c?style=for-the-badge&logo=unraid&logoColor=white" alt="Unraid" height="36"></a>&nbsp;
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-Apache--2.0-yellow?style=for-the-badge&logo=apache&logoColor=white" alt="License" height="36"></a>
</p>

<p align="center">
<b>JuiceFS</b> keeps file metadata in a database and file contents in an object
store. This container runs its <b>S3 gateway</b>, so everything on your server
that speaks S3 can talk to it. The official binary, unmodified, supervised by
s6-overlay. The file system is created on first boot, so there is no console
step between installing the template and using it.
</p>

<p align="center">
A one-knight job: I build it, keep it running, work through the issues and add what people ask for, until nothing is missing. It is free, with no accounts, no telemetry, no ads and no paid tier. No asterisk anywhere. Nothing readable ever leaves your own walls. Forged on evenings and weekends, with heart and stubbornness.
</p>

<p align="center">
If it has earned a place on your server or computer, toss a coin to your knight: it helps cover the costs and keeps the project alive. It also makes this knight's heart beat a little faster. Three ways below, whichever suits you.
</p>

<br>

<p align="center">
  <a href="https://buymeacoffee.com/junkerderprovinz"><img src="https://buttons.halleluja.design/give/buy-me-a-coffee.svg" alt="Buy me a coffee" width="160"></a>
  &nbsp;
  <a href="https://www.paypal.com/donate/?hosted_button_id=76FVV52TKXTUS"><img src="https://buttons.halleluja.design/give/paypal.svg" alt="PayPal" width="160"></a>
  &nbsp;
  <a href="https://junkerderprovinz.github.io/junkerderprovinz/"><img src="https://buttons.halleluja.design/give/crypto.svg" alt="Donate with crypto" width="160"></a>
</p>

<br>

## Table of Contents

1. [Why this container exists](#1-why-this-container-exists)
2. [What is this?](#2-what-is-this)
3. [Quick start on Unraid](#3-quick-start-on-unraid)
4. [Connecting a client](#4-connecting-a-client)
5. [Configuration](#5-configuration)
6. [Choosing where the metadata lives](#6-choosing-where-the-metadata-lives)
7. [Backup](#7-backup)
8. [How AI is used here](#8-how-ai-is-used-here)
9. [Support this project](#9-support-this-project)

<br>

## 1. Why this container exists

JuiceFS publishes two ways to run in Docker, and neither one fits a Community
Applications template.

The first is a Docker volume plugin. A plugin is not a container, so Unraid
cannot install it from a template at all. It also carries a documented flaw for
the simplest setup: with SQLite the database file ends up inside the plugin's
own container, and upstream notes that it stops working once the service
restarts.

The second is the `juicedata/mount` image, which expects you to write the whole
command line yourself, including the metadata URL, the storage backend and the
credentials. That works, but a template built on it would be a `docker run`
line in a text field, and the file system would still have to be created by
hand in a console before anything could use it.

This image closes both gaps. Every setting is an ordinary environment variable,
so every setting is a field in the template, and the file system is created on
first boot.

<br>

## 2. What is this?

The container runs `juicefs gateway`, which serves an S3 API on port 9000.

The gateway is the right mode for a server like this. It needs no FUSE, no
`--privileged` and no shared mount propagation, unlike the mount mode. A plain
port is all it takes.

Underneath, JuiceFS splits a file into two parts. The metadata, meaning names,
directories, permissions and where the pieces are, goes into a database. The
contents go into an object store as chunks. Out of the box this container puts
the database in a SQLite file under `/config` and the chunks in `/data`, so a
fresh install needs no second container and no external service.

One consequence is worth knowing before you start: because files are stored as
chunks, the contents of `/data` are not browsable. You will see JuiceFS's own
directory layout there, not your file names. Everything goes in and comes out
through the S3 gateway. If you want an S3 API in front of a share you can still
read normally with a file browser, VersityGW is the better fit.

The JuiceFS binary comes from the upstream release and is checked against the
published SHA256 during the build, so a re-tagged release fails the build
instead of shipping quietly.

<br>

## 3. Quick start on Unraid

Install the template from Community Applications, set a secret key if you want
to choose your own, and start it. Nothing else is required.

On the first start the container creates the file system and logs what it did.
If you left the secret key empty, one is generated and written to
`/config/.s3_root_password`, and the log points you at it.

On every later start it finds the existing file system and leaves it alone.
That check comes before anything else, because formatting an existing volume a
second time would orphan every object already in the store.

<br>

## 4. Connecting a client

Point any S3 client at the container:

```
Endpoint:   http://<server>:9000
Access key: juicefs          (or whatever you set as S3_ROOT_USER)
Secret key: the value you set, or the one from /config/.s3_root_password
Region:     us-east-1        (any value works, JuiceFS does not check it)
```

With the AWS CLI:

```bash
aws --endpoint-url http://<server>:9000 s3 mb s3://backups
aws --endpoint-url http://<server>:9000 s3 cp ./file.txt s3://backups/
aws --endpoint-url http://<server>:9000 s3 ls s3://backups/
```

You can create as many buckets as you like, because the container runs the
gateway in its multi-bucket mode. Each bucket is a top-level directory in the
file system. That matters more than it sounds: in the plain mode the whole file
system is a single bucket named after the volume, and creating one fails with
NoSuchBucket, which is the first thing most backup clients try to do. Set
`MULTI_BUCKETS` to `false` if you want the single-bucket behaviour instead.

<br>

## 5. Configuration

Some settings are read on every start, and some only once, when the file system
is created. That distinction matters: changing a create-only setting later has
no effect, and the log will not tell you so.

**Read on every start:**

| Variable | Default | What it does |
| --- | --- | --- |
| `META_URL` | `sqlite3:///config/juicefs.db` | Where the metadata lives. See section 6. |
| `MULTI_BUCKETS` | `true` | Whether clients can create buckets. Set to `false` for upstream's single-bucket mode, where the whole file system is one bucket named after the volume. |
| `S3_ROOT_USER` | `juicefs` | The access key clients use. |
| `S3_ROOT_PASSWORD` | generated | The secret key clients use, **at least 8 characters**. Anything shorter is refused with one clear line in the log rather than a container that restarts forever. Left empty, one is generated and stored in `/config/.s3_root_password`. |
| `CACHE_SIZE` | upstream default | Local read cache limit in MiB. |
| `CACHE_DIR` | `/cache` | Where the local read cache goes. Map it if you want the cache on a specific disk. |
| `EXTRA_ARGS` | empty | Passed to `juicefs gateway` as is, for anything not covered above. |
| `PUID` / `PGID` | `99` / `100` | The user the gateway runs as. |

**Read only when the file system is created:**

| Variable | Default | What it does |
| --- | --- | --- |
| `STORAGE` | `file` | The object store backend. `file` means a plain directory. |
| `BUCKET` | `/data/` | The path or URL of the object store. |
| `VOLUME_NAME` | `juicefs` | The name of the file system. |
| `ACCESS_KEY` | empty | Access key for a remote object store, if `STORAGE` is not `file`. |
| `SECRET_KEY` | empty | Secret key for a remote object store. |
| `TRASH_DAYS` | upstream default | How many days deleted files stay recoverable. |

To change any of the second group on an existing install, you have to create a
new file system, which means new metadata and starting over with the objects.

`STORAGE` and `BUCKET` accept every backend JuiceFS supports, so the same
container can put its chunks on another S3 server, on Backblaze B2 or on a
MinIO instance instead of on the local disk.

<br>

## 6. Choosing where the metadata lives

`META_URL` is one field, and it decides which database holds the metadata.

The default is SQLite, a single file under `/config`. For one server that is
the sensible choice: no second container, no network in between, and a backup
of `/config` captures it. What it cannot do is serve several machines writing
at once.

For that case, put a Redis or Postgres URL in the same field:

```
redis://:password@192.168.20.10:6379/1
postgres://user:password@192.168.20.10:5432/juicefs?sslmode=disable
```

Redis is what the JuiceFS project recommends for speed. Be aware that it keeps
data in memory, so its persistence settings decide whether a power cut costs
you the file system rather than just a cache.

Whichever you pick, the database is not optional and it is not a cache. The
chunks in the object store are unreadable without it. Section 7 follows from
that.

<br>

## 7. Backup

Back up the metadata database and the object store together, and from the same
point in time if you can.

With the default settings that means `/config` and `/data`. If the metadata is
in Redis or Postgres, back that database up with its own tools and keep the
schedule close to the object store's.

A backup of only the object store is not a backup. The chunks are there, but
nothing says which chunks made up which file.

<br>

## 8. How AI is used here

One knight builds this, and AI is one of the tools I work with, the same way I work with an editor or a compiler. It helps me write code and documentation and it checks my work, and that saves me a good many evenings. It does not make the decisions, though. I read and understand everything before it ships, and if something here breaks, that is on me and not on the tool.

You do not have to take my word for it. The code is open and every release note is written by hand. The issue tracker shows how problems actually get handled, including the ones I got wrong the first time. If you find something that is not right, open an issue and I will look at it.

<br>

## 9. Support this project

Questions, bugs, ideas? **[GitHub issues →](https://github.com/junkerderprovinz/juicefs/issues)**.

A one-knight job: I build it, keep it running, work through the issues and add what people ask for, until nothing is missing. It is free, with no accounts, no telemetry, no ads and no paid tier. No asterisk anywhere. Nothing readable ever leaves your own walls. Forged on evenings and weekends, with heart and stubbornness.

If it has earned a place on your server or computer, toss a coin to your knight: it helps cover the costs and keeps the project alive. It also makes this knight's heart beat a little faster. Three ways below, whichever suits you.

<p align="center">
  <a href="https://buymeacoffee.com/junkerderprovinz"><img src="https://buttons.halleluja.design/give/buy-me-a-coffee.svg" alt="Buy me a coffee" width="160"></a>
  &nbsp;
  <a href="https://www.paypal.com/donate/?hosted_button_id=76FVV52TKXTUS"><img src="https://buttons.halleluja.design/give/paypal.svg" alt="PayPal" width="160"></a>
  &nbsp;
  <a href="https://junkerderprovinz.github.io/junkerderprovinz/"><img src="https://buttons.halleluja.design/give/crypto.svg" alt="Donate with crypto" width="160"></a>
</p>
