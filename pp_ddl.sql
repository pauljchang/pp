/*
-- pp_ddl.sql
-- 
-- Creates DDL API procs
-- Should be run on local database or on a separate "pp" database
-- 
-- All objects are created within the "pp" schema
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

-- Create pp schema for all pp-related objects
IF	NOT EXISTS (
		SELECT *
		FROM
			INFORMATION_SCHEMA.SCHEMATA
		WHERE
			SCHEMA_NAME = 'pp'
	)
BEGIN
	EXEC('CREATE SCHEMA pp AUTHORIZATION dbo;');
END;
GO

-- Global logging table
IF	NOT EXISTS (
		SELECT *
		FROM
			INFORMATION_SCHEMA.TABLES
		WHERE
			INFORMATION_SCHEMA.TABLES.TABLE_SCHEMA = 'pp'
		AND	INFORMATION_SCHEMA.TABLES.TABLE_NAME   = 'changelog'
	)
BEGIN
	CREATE TABLE pp.changelog (
		id         INT           NOT NULL IDENTITY(1, 1)
			CONSTRAINT PK_log
				PRIMARY KEY NONCLUSTERED
	,	logtime    DATETIME2     NOT NULL
			CONSTRAINT DF_log_logtime
				DEFAULT (SYSUTCDATETIME())
	,	errflag    BIT           NOT NULL
			CONSTRAINT DF_log_errflag
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
	INSERT INTO pp.changelog (action, objtype, objid, dbname, schemaname, objectname, tablename, msg)
	VALUES ('CREATE', 'TABLE', OBJECT_ID('changelog'), DB_NAME(), 'dbo', 'pp.changelog', 'changelog', 'Created table pp.changelog');
	CREATE UNIQUE CLUSTERED INDEX CUX_log_logtime_id ON pp.changelog (logtime, id);
	INSERT INTO pp.changelog (action, objtype, objid, subobjid, dbname, schemaname, objectname, tablename, msg)
	VALUES (
		'CREATE'
	,	'INDEX'
	,	OBJECT_ID('changelog')
	,	(
			SELECT top 1 index_id
			FROM sys.indexes
			WHERE object_id = OBJECT_ID('pp.changelog')
			AND name = 'CUX_log_logtime_id'
		)
	,	DB_NAME()
	,	'pp'
	,	'pp.changelog.CUX_log_logtime_id'
	,	'changelog'
	,	'Created index CUX_log_logtime_id on pp.changelog'
	);
END;
GO

-- Global settings table
IF	NOT EXISTS (
		SELECT *
		FROM
			INFORMATION_SCHEMA.TABLES
		WHERE
			INFORMATION_SCHEMA.TABLES.TABLE_SCHEMA = 'pp'
		AND	INFORMATION_SCHEMA.TABLES.TABLE_NAME   = 'setting'
	)
BEGIN
	CREATE TABLE pp.setting (
		id         INT NOT NULL IDENTITY(1, 1)
			CONSTRAINT PK_setting
				PRIMARY KEY NONCLUSTERED
	,	name  VARCHAR(30) NOT NULL
	,	value VARCHAR(30) NOT NULL
	)
	ON 'PRIMARY';
	INSERT INTO pp.changelog (action, objtype, objid, dbname, schemaname, objectname, tablename, msg)
	VALUES ('CREATE', 'TABLE', OBJECT_ID('setting'), DB_NAME(), 'dbo', 'pp.setting', 'setting', 'Created table pp.setting');
	CREATE UNIQUE CLUSTERED INDEX CUX_setting_name ON pp.setting (name);
	INSERT INTO pp.changelog (action, objtype, objid, subobjid, dbname, schemaname, objectname, tablename, msg)
	VALUES (
		'CREATE'
	,	'INDEX'
	,	OBJECT_ID('setting')
	,	(
			SELECT top 1 index_id
			FROM sys.indexes
			WHERE object_id = OBJECT_ID('setting')
			AND name = 'CUX_setting_name'
		)
	,	DB_NAME()
	,	'dbo'
	,	'pp.setting.CUX_setting_name'
	,	'setting'
	,	'Created index CUX_setting_name on pp.setting'
	);
END;
GO

-- Default settings
IF	NOT EXISTS (
		SELECT *
		FROM
			pp.setting
		WHERE
			pp.setting.name = 'QUOTENAME_DELIMITER'
	)
BEGIN
	INSERT INTO pp.setting (name, value) VALUES ('QUOTENAME_DELIMITER', '[]');
END;
GO

-- Drop function if it exists
IF	EXISTS (
		SELECT *
		FROM
			INFORMATION_SCHEMA.ROUTINES
		WHERE
			INFORMATION_SCHEMA.ROUTINES.ROUTINE_SCHEMA = 'pp'
		AND	INFORMATION_SCHEMA.ROUTINES.ROUTINE_NAME   = 'tokenizer'
		AND	INFORMATION_SCHEMA.ROUTINES.ROUTINE_TYPE   = 'FUNCTION'
	)
BEGIN
	EXEC('DROP FUNCTION pp.tokenizer;');
END;
GO

-- tokenizer (@str) RETURNS TABLE
-- 
-- Utility UDF used to tokenize lists of options
-- Smart handling of parentheses and quotes
-- 
-- Ex:
-- 
-- SELECT * FROM pp.tokenizer('foo [bar] "baz" (glorp)');
-- 
-- token   strpos strlen special
-- ------- ------ ------ -------
-- foo          1      3
-- bar          6      3 []
-- baz         12      3 ""
-- glorp       18      5 ()
-- 
CREATE FUNCTION pp.tokenizer(@str NVARCHAR(MAX))
RETURNS @ret TABLE (
	token   NVARCHAR(MAX) NOT NULL
,	strpos  INT           NOT NULL
,	strlen  INT           NOT NULL
,	special CHAR(2)       NULL
)
WITH SCHEMABINDING
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

-- Stub procs
DECLARE @procs TABLE (id INT NOT NULL IDENTITY(1, 1), procname SYSNAME NOT NULL);
DECLARE @id INT, @maxid INT, @procname SYSNAME, @sql NVARCHAR(MAX);
INSERT INTO @procs (procname)
VALUES ('addcol'), ('dropcol');
SELECT @id = MIN(id) - 1, @maxid = MAX(id) FROM @procs;
WHILE (@id < @maxid)
BEGIN
	SET	@id += 1;
	SELECT @procname = procname FROM @procs WHERE id = @id;
	IF	(NOT EXISTS (
			SELECT * FROM INFORMATION_SCHEMA.ROUTINES
			WHERE ROUTINE_NAME = @procname AND ROUTINE_SCHEMA = 'pp' AND ROUTINE_TYPE = 'PROCEDURE'
			)
		)
	BEGIN
		SET	@sql = 'CREATE PROC pp.' + QUOTENAME(@procname) + ' AS RAISERROR(''Stub proc'', 11, 1);';
		EXEC sp_executesql @sql;
	END;
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
ALTER PROC pp.addcol
	@tablename  SYSNAME
,	@columnname SYSNAME
,	@datatype   SYSNAME
,	@options    NVARCHAR(MAX) = NULL
AS
BEGIN
	DECLARE
		@schemaname    SYSNAME
	,	@objid         INT
	,	@colid         INT
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
		@namedelimiter = pp.setting.value
	FROM
		pp.setting
	WHERE
		pp.setting.name = 'QUOTENAME_DELIMITER'
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
		pp.tokenizer(@options) AS opts
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
EXEC pp.addcol
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
		IF	(@notnullflag = 1)
		BEGIN
			SET	@sql += ' NOT NULL'
		END;
		ELSE
		BEGIN
			SET	@sql += ' NULL'
		END;
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
		SELECT
			@colid = sys.columns.column_id
		FROM
			sys.columns
		WHERE
			sys.columns.object_id = @objid
		AND	sys.columns.name      = @columnname
		;
		INSERT INTO pp.changelog (errflag, action, objtype, objid, subobjid, dbname, schemaname, objectname, tablename, msg)
		VALUES (
			@errflag
		,	'ADD'
		,	'COLUMN'
		,	@objid
		,	@colid
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

-- dropcol <tablename>, <columnname> [, '<options...>']
-- 
-- Drop specified column on specified table
-- If column does not exist, do nothing
-- 
-- <options> ...currently not implemented
ALTER PROC pp.dropcol
	@tablename  SYSNAME
,	@columnname SYSNAME
,	@options    NVARCHAR(MAX) = NULL
AS
BEGIN
	DECLARE
		@schemaname    SYSNAME
	,	@objid         INT
	,	@colid         INT
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
		@namedelimiter = pp.setting.value
	FROM
		pp.setting
	WHERE
		pp.setting.name = 'QUOTENAME_DELIMITER'
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
		pp.tokenizer(@options) AS opts
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
EXEC pp.dropcol
	@tablename  = ' + ISNULL('''' + REPLACE(@tablename,  '''', '''''') + '''', 'NULL') + '
,	@columnname = ' + ISNULL('''' + REPLACE(@columnname, '''', '''''') + '''', 'NULL') + '
,	@options    = ' + ISNULL('''' + REPLACE(@options,    '''', '''''') + '''', 'NULL') + '
;
*/
';
		SELECT '@opttab' AS '@opttab', * FROM @opttab;
	END;

	-- Check for existence of column
	IF	EXISTS (
			SELECT *
			FROM
				INFORMATION_SCHEMA.COLUMNS
			WHERE
				INFORMATION_SCHEMA.COLUMNS.TABLE_SCHEMA = @schemaname
			AND	INFORMATION_SCHEMA.COLUMNS.TABLE_NAME   = @tablename
			AND	INFORMATION_SCHEMA.COLUMNS.COLUMN_NAME  = @columnname
		)
	BEGIN
		SELECT
			@colid = sys.columns.column_id
		FROM
			sys.columns
		WHERE
			sys.columns.object_id = @objid
		AND	sys.columns.name      = @columnname
		;
		SET	@sql = N'
ALTER TABLE ' + QUOTENAME(@schemaname, @namedelimiter) + '.' + QUOTENAME(@tablename, @namedelimiter) + '
	DROP COLUMN ' + QUOTENAME(@columnname, @namedelimiter) + '
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
			SET	@msg = 'ERROR: addcol: Failed to drop column ' + @columnname + ' from ' + @schemaname + '.' + @tablename;
		END;
		ELSE
		BEGIN
			SET	@msg = 'addcol: Dropped column ' + @columnname + ' from ' + @schemaname + '.' + @tablename;
		END;
		INSERT INTO pp.changelog (errflag, action, objtype, objid, subobjid, dbname, schemaname, objectname, tablename, msg)
		VALUES (
			@errflag
		,	'DROP'
		,	'COLUMN'
		,	@objid
		,	@colid
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
			PRINT '-- addcol: Column already dropped';
		END;
	END;
END;
GO

/*
-- Rollback
BEGIN TRY EXEC('DROP PROC pp.addcol;');        END TRY BEGIN CATCH END CATCH;
BEGIN TRY EXEC('DROP PROC pp.dropcol;');       END TRY BEGIN CATCH END CATCH;
BEGIN TRY EXEC('DROP FUNCTION pp.tokenizer;'); END TRY BEGIN CATCH END CATCH;
BEGIN TRY EXEC('DROP TABLE pp.setting;');      END TRY BEGIN CATCH END CATCH;
BEGIN TRY EXEC('DROP TABLE pp.changelog;');    END TRY BEGIN CATCH END CATCH;
BEGIN TRY EXEC('DROP SCHEMA pp;');             END TRY BEGIN CATCH END CATCH;
*/

/*
-- Testing
SELECT * FROM pp.changelog;
SELECT * FROM pp.setting;
EXEC sp_help changelog;
EXEC sp_help setting;
SELECT * FROM pp.tokenizer('foo [bar] "baz" (glorp)');
CREATE TABLE pp.test (
	id INT NOT NULL IDENTITY(1, 1) PRIMARY KEY
);
EXEC pp.addcol 'test', 'foo', 'varchar(255)', 'NOT NULL DEFAULT (''FOO'') @@DEBUG';
EXEC pp.dropcol 'test', 'foo', '@@DEBUG';
DROP TABLE pp.test;
*/
