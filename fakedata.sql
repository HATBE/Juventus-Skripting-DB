-- Insert 20 fake PCs
INSERT INTO Computer (hostname, ipAddress, operatingSystem, lastContact)
VALUES
('PC-ALPHA01', '192.168.1.101', 'Windows 10 Pro', DATEADD(MINUTE, -10, GETDATE())),
('PC-BRAVO02', '192.168.1.102', 'Windows 11 Pro', DATEADD(MINUTE, -20, GETDATE())),
('PC-CHARLIE03', '192.168.1.103', 'Windows 10 Home', DATEADD(MINUTE, -30, GETDATE())),
('PC-DELTA04', '192.168.1.104', 'Ubuntu 22.04 LTS', DATEADD(MINUTE, -40, GETDATE())),
('PC-ECHO05', '192.168.1.105', 'Windows 11 Pro', DATEADD(MINUTE, -50, GETDATE())),
('PC-FOXTROT06', '192.168.1.106', 'Windows 10 Enterprise', DATEADD(HOUR, -1, GETDATE())),
('PC-GOLF07', '192.168.1.107', 'macOS Ventura', DATEADD(HOUR, -2, GETDATE())),
('PC-HOTEL08', '192.168.1.108', 'Windows 10 Pro', DATEADD(HOUR, -3, GETDATE())),
('PC-INDIA09', '192.168.1.109', 'Windows 11 Home', DATEADD(HOUR, -4, GETDATE())),
('PC-JULIET10', '192.168.1.110', 'Ubuntu 20.04', DATEADD(HOUR, -5, GETDATE())),
('PC-KILO11', '192.168.1.111', 'Windows 10 Pro', DATEADD(HOUR, -6, GETDATE())),
('PC-LIMA12', '192.168.1.112', 'Windows 11 Pro', DATEADD(HOUR, -7, GETDATE())),
('PC-MIKE13', '192.168.1.113', 'Windows 10 Home', DATEADD(HOUR, -8, GETDATE())),
('PC-NOVEMBER14', '192.168.1.114', 'Ubuntu 22.04', DATEADD(HOUR, -9, GETDATE())),
('PC-OSCAR15', '192.168.1.115', 'Windows 11 Pro', DATEADD(HOUR, -10, GETDATE())),
('PC-PAPA16', '192.168.1.116', 'Windows 10 Enterprise', DATEADD(HOUR, -11, GETDATE())),
('PC-QUEBEC17', '192.168.1.117', 'macOS Sonoma', DATEADD(HOUR, -12, GETDATE())),
('PC-ROMEO18', '192.168.1.118', 'Windows 10 Pro', DATEADD(HOUR, -13, GETDATE())),
('PC-SIERRA19', '192.168.1.119', 'Windows 11 Home', DATEADD(HOUR, -14, GETDATE())),
('PC-TANGO20', '192.168.1.120', 'Ubuntu 20.04', DATEADD(HOUR, -15, GETDATE()));
GO

-- insert 100 fake measurements
DECLARE @i INT = 0;
DECLARE @computerCount INT = (SELECT COUNT(*) FROM Computer);
DECLARE @randComputerId INT;
DECLARE @cpu FLOAT;
DECLARE @ramUsed INT;
DECLARE @ramTotal INT;
DECLARE @diskUsed FLOAT;
DECLARE @diskTotal FLOAT;
DECLARE @uptime INT;

WHILE @i < 100
BEGIN
    -- Random computerId
    SELECT TOP 1 @randComputerId = computerId FROM Computer ORDER BY NEWID();

    -- Generate fake values
    SET @cpu = ROUND(RAND() * 100, 2); -- 0 to 100%
    SET @ramTotal = 4096 + (ABS(CHECKSUM(NEWID())) % 12288); -- 4GB to 16GB
    SET @ramUsed = FLOOR(@ramTotal * (0.3 + RAND() * 0.7)); -- 30% to 100% usage

    SET @diskTotal = 100 + (ABS(CHECKSUM(NEWID())) % 900); -- 100GB to 1000GB
    SET @diskUsed = FLOOR(@diskTotal * (0.2 + RAND() * 0.8)); -- 20% to 100% usage

    SET @uptime = 100 + (ABS(CHECKSUM(NEWID())) % 100000); -- Random uptime

    -- Insert measurement
    INSERT INTO Measurement (computerId, timestamp, cpuUsagePercent, ramUsedMB, ramTotalMB, diskUsedGB, diskTotalGB, uptimeMinutes)
    VALUES (
        @randComputerId,
        DATEADD(MINUTE, -1 * ABS(CHECKSUM(NEWID())) % 10000, GETDATE()), -- Random time in past ~7 days
        @cpu,
        @ramUsed,
        @ramTotal,
        @diskUsed,
        @diskTotal,
        @uptime
    );

    SET @i = @i + 1;
END
GO