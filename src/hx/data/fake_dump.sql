-- MySQL dump 10.13  Distrib 5.5.54, for debian-linux-gnu (x86_64)
-- Host: localhost    Database: system_config
-- Server version	5.5.54-0ubuntu0.14.04.1

/*!40101 SET @OLD_CHARACTER_SET_CLIENT=@@CHARACTER_SET_CLIENT */;
CREATE TABLE `users` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `username` varchar(64) NOT NULL,
  `password_hash` varchar(255) NOT NULL,
  `role` enum('admin','operator','viewer') NOT NULL DEFAULT 'viewer',
  PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8;
INSERT INTO `users` VALUES (1,'root','$6$rounds=656000$Kj9sXp2VbN0qZtWc$XWZ/QLjP/Q8bDy7uKc2sV9fEa1GhN4Rt3Wm5Vx8Yz0Cd6Lp2Tq7Jf1Sb4No8Ma3Ub9Ke5Oi7Qd9Yt3Wf1','admin'),(2,'sys_admin','$6$rounds=656000$Q2mzC8oR1pW4tXn9$Ae3Gh7Lj2Mk5Pq9Rs0Tu6Vx4Wz8Yb1Cd3Ef5Gj7Hl2Km4Np6Qr9St1Uv3Wx8Yz0Ab5','admin'),(3,'backup','$6$rounds=656000$L8r4Cv7yN2hB5kFq$Uv1Wd3Xf5Gh6Jk8Lm9Np1Qr3St4Uv6Wx8Yz0Ab2Cd4Ef7Gh9Jk1Lm3Np5Qr7St9Uv2Wx4Yz6Ab8','operator');

CREATE TABLE `credentials` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `service` varchar(32) NOT NULL,
  `username` varchar(64) NOT NULL,
  `password` varchar(128) NOT NULL,
  PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8;
INSERT INTO `credentials` VALUES (1,'vpn_primary','netadmin','test_password'),(2,'vpn_secondary','netadmin','test_password'),(3,'nas_admin','admin','test_password'),(4,'router_cfg','cisco','test_password'),(5,'api_dashboard','apiuser','test_password');

CREATE TABLE `backup_servers` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `host` varchar(255) NOT NULL,
  `username` varchar(64) NOT NULL,
  `password` varchar(128) NOT NULL,
  PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8;
INSERT INTO `backup_servers` VALUES (1,'10.0.0.5','admin','test_password'),(2,'backup.dc.example.com','archive','test_password');

CREATE TABLE `api_keys` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `service` varchar(32) NOT NULL,
  `api_key` varchar(128) NOT NULL,
  PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8;
INSERT INTO `api_keys` VALUES (1,'payment','test_key'),(2,'cloud_sync','test_key'),(3,'monitoring','test_key');
