/*
-- pp_ddl.sql
-- 
-- Creates DDL API procs
-- Should be run on local database or on separate "pp" database
-- 
-- All procs are created within the DBO schema
*/

-- If there is a deadlock, kill this session (we can always rerun it)
SET DEADLOCK_PRIORITY LOW;
-- Concat NULL should yield NULL, which is ANSI-compliant
-- CONCAT_NULL_YIELDS_NULL OFF will be deprecated in future versions
SET CONCAT_NULL_YIELDS_NULL ON;
-- Use ANSI/ISO rules
-- This turns on the following settings:
--   ANSI_NULLS
--   ANSI_NULL_DFLT_ON
--   ANSI_PADDING
--   ANSI_WARNINGS
--   CURSOR_CLOSE_ON_COMMIT
--   IMPLICIT_TRANSACTIONS
--   QUOTED_IDENTIFIER
SET ANSI_DEFAULTS ON;
-- We do not want IMPLICIT_TRANSACTIONS
SET IMPLICIT_TRANSACTIONS OFF;
-- Reduce verbosity of query output
SET NOCOUNT ON;
GO

-- Global logging table
IF	OBJECT_ID('pp_log') IS NULL
BEGIN
	CREATE TABLE dbo.pp_log (
		id         INT           NOT NULL IDENTITY(1, 1)
			CONSTRAINT PK_pp_log
				PRIMARY KEY NONCLUSTERED
	,	logtime    DATETIME2     NOT NULL
			CONSTRAINT DF_pp_log_logtime
				DEFAULT (SYSUTCDATETIME())
	,	errflag    BIT           NOT NULL
			CONSTRAINT DF_pp_log_errflag
				DEFAULT (0)
	,	objid      INT           NULL
	,	subobjid   INT           NULL
	,	action     CHAR(10)      NULL -- CREATE, DROP, ADD, ALTER, etc.
	,	objtype    CHAR(10)      NULL -- TABLE, COLUMN, INDEX, etc.
	,	dbname     SYSNAME       NULL
	,	schemaname SYSNAME       NULL
	,	objectname SYSNAME       NULL
	,	tablename  SYSNAME       NULL
	,	columnname SYSNAME       NULL
	,	msg        NVARCHAR(MAX) NULL
	)
	ON 'PRIMARY';
	INSERT INTO dbo.pp_log (action, objtype, objid, dbname, schemaname, objectname, tablename, msg)
	VALUES ('CREATE', 'TABLE', OBJECT_ID('pp_log'), DB_NAME(), 'dbo', 'dbo.pp_log', 'pp_log', 'Created table dbo.pp_log');
	CREATE UNIQUE CLUSTERED INDEX CUX_pp_log_logtime_id ON pp_log (logtime, id);
	INSERT INTO dbo.pp_log (action, objtype, objid, subobjid, dbname, schemaname, objectname, tablename, msg)
	VALUES (
		'CREATE'
	,	'INDEX'
	,	OBJECT_ID('pp_log')
	,	(
			SELECT top 1 index_id
			FROM sys.indexes
			WHERE object_id = OBJECT_ID('pp_log')
			AND name = 'CUX_pp_log_logtime_id'
		)
	,	DB_NAME()
	,	'dbo'
	,	'dbo.pp_log.CUX_pp_log_logtime_id'
	,	'pp_log'
	,	'Created index CUX_pp_log_logtime_id on dbo.pp_log'
	);
END;
GO

-- Global settings table
IF	OBJECT_ID('pp_setting') IS NULL
BEGIN
	CREATE TABLE dbo.pp_setting (
		id         INT NOT NULL IDENTITY(1, 1)
			CONSTRAINT PK_pp_setting
				PRIMARY KEY NONCLUSTERED
	,	name  VARCHAR(30) NOT NULL
	,	value VARCHAR(30) NOT NULL
	)
	ON 'PRIMARY';
	INSERT INTO dbo.pp_log (action, objtype, objid, dbname, schemaname, objectname, tablename, msg)
	VALUES ('CREATE', 'TABLE', OBJECT_ID('pp_setting'), DB_NAME(), 'dbo', 'dbo.pp_setting', 'pp_setting', 'Created table dbo.pp_setting');
	CREATE UNIQUE CLUSTERED INDEX CUX_pp_setting_name ON pp_setting (name);
	INSERT INTO dbo.pp_log (action, objtype, objid, subobjid, dbname, schemaname, objectname, tablename, msg)
	VALUES (
		'CREATE'
	,	'INDEX'
	,	OBJECT_ID('pp_setting')
	,	(
			SELECT top 1 index_id
			FROM sys.indexes
			WHERE object_id = OBJECT_ID('pp_setting')
			AND name = 'CUX_pp_setting_name'
		)
	,	DB_NAME()
	,	'dbo'
	,	'dbo.pp_setting.CUX_pp_setting_name'
	,	'pp_setting'
	,	'Created index CUX_pp_setting_name on dbo.pp_setting'
	);
END;
GO

-- Default settings
IF	NOT EXISTS (SELECT * FROM dbo.pp_setting WHERE name = 'QUOTENAME_DELIMITER')
BEGIN
	INSERT INTO pp_setting (name, value) VALUES ('QUOTENAME_DELIMITER', '[]');
END;
GO

-- Stub function
IF	OBJECT_ID('pp_tokenizer') IS NULL
BEGIN
	EXEC('CREATE FUNCTION dbo.pp_tokenizer() RETURNS @foo TABLE (foo INT NULL) AS BEGIN RETURN; END;');
END;
GO

-- pp_tokenizer (@str) RETURNS TABLE
-- 
-- Utility UDF used to tokenize lists of options
-- Smart handling of parentheses and quotes
-- 
-- Ex:
-- 
-- SELECT * FROM dbo.pp_tokenizer('foo [bar] "baz" (glorp)');
-- 
-- token   strpos strlen special
-- ------- ------ ------ -------
-- foo          1      3
-- bar          6      3 []
-- baz         12      3 ""
-- glorp       18      5 ()
-- 
ALTER FUNCTION dbo.pp_tokenizer(@str NVARCHAR(MAX))
RETURNS @ret TABLE (
	token   NVARCHAR(MAX) NOT NULL
,	strpos  INT           NOT NULL
,	strlen  INT           NOT NULL
,	special CHAR(2)       NULL
)
AS
BEGIN
	DECLARE
		@strpos    INT           = 0
	,	@maxstrpos INT           = LEN(@str)
	,	@tokenpos  INT           = 1
	,	@strlen    INT           = 0
	,	@char      NCHAR(1)      = NULL
	,	@token     NVARCHAR(MAX) = ''
	,	@special   VARCHAR(2)    = NULL -- not CHAR, to facilitate concatenation
	-- white-space delimiters
	,	@space     CHAR(1)       = ' '
	,	@tab       CHAR(1)       = '	'
	,	@newline   CHAR(2)       = '
'
	,	@cr        CHAR(1)       = CHAR(13)
	,	@lf        CHAR(1)       = CHAR(10)
	-- debugging
	,	@debugflag BIT           = 0
	;
	WHILE @strpos < @maxstrpos
	BEGIN
		SET	@strpos += 1;
		SET	@char = SUBSTRING(@str, @strpos, 1);
		-- Debug
		IF	(@debugflag = 1)
		BEGIN
			INSERT INTO @ret (token, strpos, strlen, special)
			VALUES ('-- @char = ' + ISNULL('''' + @char + '''', '?'), @strpos, 0, @special);
		END;
		-- Check for special nesting characters
		IF	(
				ISNULL(@special, '') = ''
			)
		AND	@char IN ('(', '[', '{', '"', '''')
		BEGIN
			SET	@special = @char;
			-- Debug
			IF	(@debugflag = 1)
			BEGIN
				INSERT INTO @ret (token, strpos, strlen, special)
				VALUES ('-- Open nesting', @strpos, 0, @special);
			END;
		END;
		-- If we are already nesting, check ending
		-- or if not nesting check delimiter
		-- or if we are at the end of the string
		ELSE IF (
				@special + @char IN ('()', '[]', '{}', '""', '''''')
			OR	(
					@char IN (@space, @tab, @newline, @cr, @lf)
				AND	ISNULL(@special, '') = ''
				AND	@token <> ''
				)
			OR	@strpos = @maxstrpos
			)
		BEGIN
			-- Special handling for special nesting
			-- Flush token and reset variables
			IF	(@special + @char IN ('()', '[]', '{}', '""', ''''''))
			BEGIN
				SET	@special += @char;
				SET	@char = '';
				-- Debug
				IF	(@debugflag = 1)
				BEGIN
					INSERT INTO @ret (token, strpos, strlen, special)
					VALUES ('-- Close nesting', @strpos, 0, @special);
				END;
			END;
			IF	@char <> ''
			BEGIN
				SET	@token += @char;
				-- Debug
				IF	(@debugflag = 1)
				BEGIN
					INSERT INTO @ret (token, strpos, strlen, special)
					VALUES ('-- Close token, @token = ' + ISNULL('''' + REPLACE(@token, '''', '''''') + '''', 'NULL'), @strpos, 0, @special);
				END;
			END;
			-- Debug
			IF	(@debugflag = 1)
			BEGIN
				INSERT INTO @ret (token, strpos, strlen, special)
				VALUES ('-- Flush token, @token = ' + ISNULL('''' + REPLACE(@token, '''', '''''') + '''', 'NULL'), @strpos, 0, @special);
			END;
			INSERT INTO @ret (token, strpos, strlen, special)
			VALUES (@token, @tokenpos, @strpos - @tokenpos, @special);
			SET	@token    = '';
			SET	@tokenpos = @strpos;
			SET	@special  = NULL;
		END;
		-- Otherwise, build up the token
		ELSE IF (
					ISNULL(@special, '') <> ''
				OR	@char NOT IN (@space, @tab, @newline, @cr, @lf)
			)
		BEGIN
			IF	@token = ''
			BEGIN
				SET	@tokenpos = @strpos;
				-- Debug
				IF	(@debugflag = 1)
				BEGIN
					INSERT INTO @ret (token, strpos, strlen, special)
					VALUES ('-- Open new token', @strpos, 0, @special);
				END;
			END;
			SET	@token += @char;
			-- Building token
			IF	(@debugflag = 1)
			BEGIN
				INSERT INTO @ret (token, strpos, strlen, special)
				VALUES ('-- Build token, @token = ' + ISNULL('''' + REPLACE(@token, '''', '''''') + '''', 'NULL'), @strpos, 0, @special);
			END;
		END;
	END;
	RETURN;
END;
GO

-- Stub proc
IF	OBJECT_ID('addcol') IS NULL
BEGIN
	EXEC('CREATE PROC dbo.addcol AS RAISERROR(''Stub proc'', 11, 1);');
END;
GO

-- addcol <tablename>, <columnname>, <datatype> [, '<options...>']
-- 
-- Adds specified column to specified table
-- If column already exists, do nothing
-- 
-- <options> =
--	['NOT NULL' | 'NULL']
--	'DEFAULT (<value>)'
ALTER PROC dbo.addcol
	@tablename  SYSNAME
,	@columnname SYSNAME
,	@datatype   SYSNAME
,	@options    NVARCHAR(MAX) = NULL
AS
BEGIN
	DECLARE
		@schemaname    SYSNAME
	,	@objid         INT
	-- String processing of @options
	,	@token         NVARCHAR(MAX)
	,	@token2        NVARCHAR(MAX)
	,	@id            INT
	,	@maxid         INT
	-- Processed option values
	,	@notnullflag   BIT           = 0
	,	@defaultvalue  NVARCHAR(MAX) = NULL
	,	@debugflag     BIT           = 0
	,	@noexecflag    BIT           = 0
	-- Dynamic SQL
	,	@namedelimiter CHAR(2) = '[]'
	,	@sql           NVARCHAR(MAX)
	,	@msg           NVARCHAR(MAX)
	-- Error handling
	,	@errnum        INT
	,	@errsev        INT
	,	@errstate      INT
	,	@errproc       SYSNAME
	,	@errline       INT
	,	@errmsg        NVARCHAR(MAX)
	,	@errflag       BIT = 0
	;

	SELECT
		@namedelimiter = dbo.pp_setting.value
	FROM
		dbo.pp_setting
	WHERE
		dbo.pp_setting.name = 'QUOTENAME_DELIMITER'
	;

	-- Decompose schemaname.tablename, if necessary
	IF	@tablename LIKE '%.%'
	BEGIN
		SELECT
			@schemaname = INFORMATION_SCHEMA.TABLES.TABLE_SCHEMA
		,	@tablename  = INFORMATION_SCHEMA.TABLES.TABLE_NAME
		FROM
			INFORMATION_SCHEMA.TABLES
		WHERE
			INFORMATION_SCHEMA.TABLES.TABLE_TYPE = 'BASE TABLE'
		AND	@tablename IN (
				INFORMATION_SCHEMA.TABLES.TABLE_SCHEMA + '.' + INFORMATION_SCHEMA.TABLES.TABLE_NAME
			,	QUOTENAME(INFORMATION_SCHEMA.TABLES.TABLE_SCHEMA) + '.' + QUOTENAME(INFORMATION_SCHEMA.TABLES.TABLE_NAME)
			,	QUOTENAME(INFORMATION_SCHEMA.TABLES.TABLE_SCHEMA, '"') + '.' + QUOTENAME(INFORMATION_SCHEMA.TABLES.TABLE_NAME, '"')
			)
		;
	END;
	ELSE
	-- Otherwise, look up schema name and table name
	BEGIN
		SELECT
			@schemaname = INFORMATION_SCHEMA.TABLES.TABLE_SCHEMA
		,	@tablename  = INFORMATION_SCHEMA.TABLES.TABLE_NAME
		FROM
			INFORMATION_SCHEMA.TABLES
		WHERE
			INFORMATION_SCHEMA.TABLES.TABLE_TYPE = 'BASE TABLE'
		AND	INFORMATION_SCHEMA.TABLES.TABLE_NAME = @tablename
		;
	END;

	-- Find object ID
	SELECT
		@objid = sys.tables.object_id
	FROM
		sys.tables
	WHERE
		sys.tables.name      = @tablename
	AND	sys.tables.schema_id = SCHEMA_ID(@schemaname)
	;

	-- Process options
	DECLARE @opttab TABLE (
		id      INT           NOT NULL IDENTITY(1, 1) PRIMARY KEY CLUSTERED
	,	token   NVARCHAR(MAX) NOT NULL
	,	special CHAR(2)       NULL
	);
	INSERT INTO @opttab (token, special)
	SELECT
		opts.token
	,	opts.special
	FROM
		dbo.pp_tokenizer(@options) AS opts
	;
	SELECT
		@id    = 0
	,	@maxid = MAX(opttab.id)
	FROM
		@opttab AS opttab
	;
	WHILE (@id < @maxid)
	BEGIN
		SET	@id += 1;
		SELECT
			@token  = opttab.token
		,	@token2 = nextopttab.token
		FROM
			@opttab AS opttab
			LEFT OUTER JOIN @opttab AS nextopttab
			ON	nextopttab.id = opttab.id + 1
		WHERE
			opttab.id = @id
		;
		-- Nullability
		IF	(@token = 'NOT' AND @token2 = 'NULL')
		BEGIN
			SET	@notnullflag = 1;
			SET	@id += 1;
		END;
		ELSE IF (@token = 'NULL')
		BEGIN
			SET	@notnullflag = 0;
		END;
		-- Default
		IF	(@token = 'DEFAULT' AND @token2 <> '')
		BEGIN
			SET	@defaultvalue = @token2;
			SET	@id += 1;
		END;
		-- Debug
		IF	(@token = '@@DEBUG')
		BEGIN
			SET	@debugflag = 1;
		END;
	END;

	-- Debug
	IF	@debugflag = 1
	BEGIN
		PRINT '/*
EXEC dbo.addcol
	@tablename  = ' + ISNULL('''' + REPLACE(@tablename,  '''', '''''') + '''', 'NULL') + '
,	@columnname = ' + ISNULL('''' + REPLACE(@columnname, '''', '''''') + '''', 'NULL') + '
,	@datatype   = ' + ISNULL('''' + REPLACE(@datatype,   '''', '''''') + '''', 'NULL') + '
,	@options    = ' + ISNULL('''' + REPLACE(@options,    '''', '''''') + '''', 'NULL') + '
;
*/
';
		SELECT '@opttab' AS '@opttab', * FROM @opttab;
	END;

	-- Check for existence of column
	IF	NOT EXISTS (
			SELECT *
			FROM
				INFORMATION_SCHEMA.COLUMNS
			WHERE
				INFORMATION_SCHEMA.COLUMNS.TABLE_SCHEMA = @schemaname
			AND	INFORMATION_SCHEMA.COLUMNS.TABLE_NAME   = @tablename
			AND	INFORMATION_SCHEMA.COLUMNS.COLUMN_NAME  = @columnname
		)
	BEGIN
		SET	@sql = N'
ALTER TABLE ' + QUOTENAME(@schemaname, @namedelimiter) + '.' + QUOTENAME(@tablename, @namedelimiter) + '
	ADD ' + QUOTENAME(@columnname, @namedelimiter) + ' ' + @datatype;
		IF	(@defaultvalue IS NOT NULL)
		BEGIN
			SET	@sql += '
	CONSTRAINT ' + QUOTENAME('DF_' + @tablename + '_' + @columnname, @namedelimiter) + '
		DEFAULT (' + @defaultvalue + ')'
		END;
		SET	@sql += '
;';
		-- Debug
		IF	@debugflag = 1
		BEGIN
			PRINT @sql;
		END;
		BEGIN TRY
			EXEC sp_executesql @sql;
		END TRY
		BEGIN CATCH
			SELECT
				@errflag  = 1
			,	@errnum   = ERROR_NUMBER()
			,	@errsev   = ERROR_SEVERITY()
			,	@errstate = ERROR_STATE()
			,	@errproc  = ERROR_PROCEDURE()
			,	@errline  = ERROR_LINE()
			,	@errmsg   = ERROR_MESSAGE()
			;
			THROW;
		END CATCH;
		IF	@errflag = 1
		BEGIN
			SET	@msg = 'ERROR: addcol: Failed to add column ' + @columnname + ' to ' + @schemaname + '.' + @tablename;
		END;
		ELSE
		BEGIN
			SET	@msg = 'addcol: Added column ' + @columnname + ' to ' + @schemaname + '.' + @tablename;
		END;
		INSERT INTO dbo.pp_log (errflag, action, objtype, objid, subobjid, dbname, schemaname, objectname, tablename, msg)
		VALUES (
			@errflag
		,	'ADD'
		,	'COLUMN'
		,	@objid
		,	(
				SELECT TOP 1
					sys.columns.column_id
				FROM
					sys.columns
				WHERE
					sys.columns.object_id = @objid
				AND	sys.columns.name = @columnname
			)
		,	DB_NAME()
		,	@schemaname
		,	@schemaname + '.' + @tablename + '.' + @columnname
		,	@tablename
		,	@msg
		);
	END;
	ELSE
	BEGIN
		IF	(@debugflag = 1)
		BEGIN
			PRINT '-- addcol: Column already exists';
		END;
	END;
END;
GO

/*
-- Testing
SELECT * FROM pp_log;
SELECT * FROM pp_setting;
IF OBJECT_ID('addcol') IS NULL DROP PROC addcol;
IF OBJECT_ID('pp_tokenizer') IS NULL DROP FUNCTION pp_tokenizer;
IF OBJECT_ID('pp_setting') IS NOT NULL DROP TABLE dbo.pp_setting;
IF OBJECT_ID('pp_log') IS NOT NULL DROP TABLE dbo.pp_log;
EXEC sp_help pp_log;
EXEC sp_help pp_setting;
SELECT * FROM dbo.pp_tokenizer('foo [bar] "baz" (glorp)');
CREATE TABLE dbo.test (
	id INT NOT NULL IDENTITY(1, 1) PRIMARY KEY
);
EXEC addcol 'test', 'foo', 'varchar(255)', '@@DEBUG DEFAULT (''FOO'')';
DROP TABLE dbo.test;
*/
