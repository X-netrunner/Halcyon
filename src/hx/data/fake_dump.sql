CREATE TABLE `credentials` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `service` varchar(32) NOT NULL,
  `username` varchar(64) NOT NULL,
  `password` varchar(128) NOT NULL,
  PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8;
INSERT INTO `credentials` VALUES (1,'vpn_primary','test_user','test_password'),(2,'vpn_secondary','test_user','test_password'),(3,'nas_admin','admin','test_password'),(4,'router_cfg','admin','test_password'),(5,'api_dashboard','apiuser','test_password');

CREATE TABLE `backup_servers` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `host` varchar(255) NOT NULL,
  `username` varchar(64) NOT NULL,
  `password` varchar(128) NOT NULL,
  PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8;
INSERT INTO `backup_servers` VALUES (1,'10.0.0.5','test','test_password'),(2,'backup.example.com','test','test_password');

CREATE TABLE `api_keys` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `service` varchar(32) NOT NULL,
  `api_key` varchar(128) NOT NULL,
  PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8;
INSERT INTO `api_keys` VALUES (1,'payment','test_key'),(2,'cloud_sync','test_key'),(3,'monitoring','test_key');
