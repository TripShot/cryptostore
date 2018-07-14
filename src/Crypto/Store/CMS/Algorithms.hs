-- |
-- Module      : Crypto.Store.CMS.Algorithms
-- License     : BSD-style
-- Maintainer  : Olivier Chéron <olivier.cheron@gmail.com>
-- Stability   : experimental
-- Portability : unknown
--
-- Cryptographic Message Syntax algorithms
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeFamilies #-}
module Crypto.Store.CMS.Algorithms
    ( DigestType(..)
    , DigestAlgorithm(..)
    , MessageAuthenticationCode
    , MACAlgorithm(..)
    , mac
    , HasKeySize(..)
    , getMaximumKeySize
    , validateKeySize
    , generateKey
    , ContentEncryptionCipher(..)
    , ContentEncryptionAlg(..)
    , ContentEncryptionParams(..)
    , generateEncryptionParams
    , getContentEncryptionAlg
    , proxyBlockSize
    , contentEncrypt
    , contentDecrypt
    , PBKDF2_PRF(..)
    , prf
    , Salt
    , generateSalt
    , KeyDerivationFunc(..)
    , kdfKeyLength
    , kdfDerive
    , KeyEncryptionParams(..)
    , keyEncrypt
    , keyDecrypt
    ) where

import           Data.ASN1.OID
import           Data.ASN1.Types
import           Data.Bits
import           Data.ByteArray (ByteArray, ByteArrayAccess)
import qualified Data.ByteArray as B
import           Data.ByteString (ByteString)
import           Data.Word

import qualified Crypto.Cipher.AES as Cipher
import qualified Crypto.Cipher.CAST5 as Cipher
import qualified Crypto.Cipher.Camellia as Cipher
import qualified Crypto.Cipher.DES as Cipher
import qualified Crypto.Cipher.TripleDES as Cipher
import           Crypto.Cipher.Types
import           Crypto.Data.Padding
import           Crypto.Error
import qualified Crypto.Hash as Hash
import qualified Crypto.KDF.PBKDF2 as PBKDF2
import qualified Crypto.KDF.Scrypt as Scrypt
import qualified Crypto.MAC.HMAC as HMAC
import           Crypto.Random

import           Crypto.Store.ASN1.Generate
import           Crypto.Store.ASN1.Parse
import           Crypto.Store.CMS.Util
import qualified Crypto.Store.KeyWrap.AES as AES_KW
import qualified Crypto.Store.KeyWrap.TripleDES as TripleDES_KW


-- Hash functions

-- | CMS digest algorithm.
data DigestAlgorithm hashAlg where
    -- | MD5
    MD5    :: DigestAlgorithm Hash.MD5
    -- | SHA-1
    SHA1   :: DigestAlgorithm Hash.SHA1
    -- | SHA-224
    SHA224 :: DigestAlgorithm Hash.SHA224
    -- | SHA-256
    SHA256 :: DigestAlgorithm Hash.SHA256
    -- | SHA-384
    SHA384 :: DigestAlgorithm Hash.SHA384
    -- | SHA-512
    SHA512 :: DigestAlgorithm Hash.SHA512

deriving instance Show (DigestAlgorithm hashAlg)
deriving instance Eq (DigestAlgorithm hashAlg)

-- | Existential CMS digest algorithm.
data DigestType =
    forall hashAlg . Hash.HashAlgorithm hashAlg
        => DigestType (DigestAlgorithm hashAlg)

instance Show DigestType where
    show (DigestType a) = show a

instance Eq DigestType where
    DigestType MD5    == DigestType MD5    = True
    DigestType SHA1   == DigestType SHA1   = True
    DigestType SHA224 == DigestType SHA224 = True
    DigestType SHA256 == DigestType SHA256 = True
    DigestType SHA384 == DigestType SHA384 = True
    DigestType SHA512 == DigestType SHA512 = True
    _                 == _                 = False

instance Enumerable DigestType where
    values = [ DigestType MD5
             , DigestType SHA1
             , DigestType SHA224
             , DigestType SHA256
             , DigestType SHA384
             , DigestType SHA512
             ]

instance OIDable DigestType where
    getObjectID (DigestType MD5)    = [1,2,840,113549,2,5]
    getObjectID (DigestType SHA1)   = [1,3,14,3,2,26]
    getObjectID (DigestType SHA224) = [2,16,840,1,101,3,4,2,4]
    getObjectID (DigestType SHA256) = [2,16,840,1,101,3,4,2,1]
    getObjectID (DigestType SHA384) = [2,16,840,1,101,3,4,2,2]
    getObjectID (DigestType SHA512) = [2,16,840,1,101,3,4,2,3]

instance OIDNameable DigestType where
    fromObjectID oid = unOIDNW <$> fromObjectID oid


-- Cipher-like things

-- | Algorithms that are based on a secret key.  This includes ciphers but also
-- MAC algorithms.
class HasKeySize params where
    -- | Get a specification of the key sizes allowed by the algorithm.
    getKeySizeSpecifier :: params -> KeySizeSpecifier

-- | Return the maximum key size for the specified algorithm.
getMaximumKeySize :: HasKeySize params => params -> Int
getMaximumKeySize params =
    case getKeySizeSpecifier params of
        KeySizeRange _ n -> n
        KeySizeEnum  l   -> maximum l
        KeySizeFixed n   -> n

-- | Return 'True' if the specified key size is valid for the specified
-- algorithm.
validateKeySize :: HasKeySize params => params -> Int -> Bool
validateKeySize params len =
    case getKeySizeSpecifier params of
        KeySizeRange a b -> a <= len && len <= b
        KeySizeEnum  l   -> len `elem` l
        KeySizeFixed n   -> len == n

-- | Generate a random key suitable for the specified algorithm.  This uses the
-- maximum size allowed by the parameters.
generateKey :: (HasKeySize params, MonadRandom m, ByteArray key)
            => params -> m key
generateKey params = getRandomBytes (getMaximumKeySize params)


-- MAC

-- | Message authentication code.  Equality is time constant.
type MessageAuthenticationCode = AuthTag

-- | Message Authentication Code (MAC) Algorithm.
data MACAlgorithm
    = forall hashAlg . Hash.HashAlgorithm hashAlg
        => HMAC (DigestAlgorithm hashAlg)

deriving instance Show MACAlgorithm

instance Eq MACAlgorithm where
    HMAC a1 == HMAC a2 = DigestType a1 == DigestType a2

instance Enumerable MACAlgorithm where
    values = map (\(DigestType a) -> HMAC a) values

instance OIDable MACAlgorithm where
    getObjectID (HMAC MD5)    = [1,3,6,1,5,5,8,1,1]
    getObjectID (HMAC SHA1)   = [1,3,6,1,5,5,8,1,2]
    getObjectID (HMAC SHA224) = [1,2,840,113549,2,8]
    getObjectID (HMAC SHA256) = [1,2,840,113549,2,9]
    getObjectID (HMAC SHA384) = [1,2,840,113549,2,10]
    getObjectID (HMAC SHA512) = [1,2,840,113549,2,11]

instance OIDNameable MACAlgorithm where
    fromObjectID oid = unOIDNW <$> fromObjectID oid

instance AlgorithmId MACAlgorithm where
    type AlgorithmType MACAlgorithm = MACAlgorithm
    algorithmName _  = "mac algorithm"
    algorithmType    = id
    parameterASN1S _ = id
    parseParameter p = getNextMaybe nullOrNothing >> return p

instance HasKeySize MACAlgorithm where
    getKeySizeSpecifier (HMAC a) = KeySizeFixed (digestSizeFromProxy a)
      where digestSizeFromProxy = Hash.hashDigestSize . hashFromProxy
            hashFromProxy :: proxy a -> a
            hashFromProxy _ = undefined

-- | Invoke the MAC function.
mac :: (ByteArrayAccess key, ByteArrayAccess message)
     => MACAlgorithm -> key -> message -> MessageAuthenticationCode
mac (HMAC alg) = hmacWith alg
  where
    hmacWith p key = AuthTag . B.convert . runHMAC p key

    runHMAC :: (Hash.HashAlgorithm a, ByteArrayAccess k, ByteArrayAccess m)
        => proxy a -> k -> m -> HMAC.HMAC a
    runHMAC _ = HMAC.hmac


-- Content encryption

-- | CMS content encryption cipher.
data ContentEncryptionCipher cipher where
    -- | DES
    DES         :: ContentEncryptionCipher Cipher.DES
    -- | Triple-DES with 2 keys used in alternative direction
    DES_EDE2    :: ContentEncryptionCipher Cipher.DES_EDE2
    -- | Triple-DES with 3 keys used in alternative direction
    DES_EDE3    :: ContentEncryptionCipher Cipher.DES_EDE3
    -- | AES with 128-bit key
    AES128      :: ContentEncryptionCipher Cipher.AES128
    -- | AES with 192-bit key
    AES192      :: ContentEncryptionCipher Cipher.AES192
    -- | AES with 256-bit key
    AES256      :: ContentEncryptionCipher Cipher.AES256
    -- | CAST5 (aka CAST-128) with key between 40 and 128 bits
    CAST5       :: ContentEncryptionCipher Cipher.CAST5
    -- | Camellia with 128-bit key
    Camellia128 :: ContentEncryptionCipher Cipher.Camellia128

deriving instance Show (ContentEncryptionCipher cipher)
deriving instance Eq (ContentEncryptionCipher cipher)

cecI :: ContentEncryptionCipher c -> Int
cecI DES         = 0
cecI DES_EDE2    = 1
cecI DES_EDE3    = 2
cecI AES128      = 3
cecI AES192      = 4
cecI AES256      = 5
cecI CAST5       = 6
cecI Camellia128 = 7

getCipherKeySizeSpecifier :: Cipher cipher => proxy cipher -> KeySizeSpecifier
getCipherKeySizeSpecifier = cipherKeySize . cipherFromProxy

-- | Cipher and mode of operation for content encryption.
data ContentEncryptionAlg
    = forall c . BlockCipher c => ECB (ContentEncryptionCipher c)
      -- ^ Electronic Codebook
    | forall c . BlockCipher c => CBC (ContentEncryptionCipher c)
      -- ^ Cipher Block Chaining
    | forall c . BlockCipher c => CFB (ContentEncryptionCipher c)
      -- ^ Cipher Feedback
    | forall c . BlockCipher c => CTR (ContentEncryptionCipher c)
      -- ^ Counter

instance Show ContentEncryptionAlg where
    show (ECB c) = shows c "_ECB"
    show (CBC c) = shows c "_CBC"
    show (CFB c) = shows c "_CFB"
    show (CTR c) = shows c "_CTR"

instance Enumerable ContentEncryptionAlg where
    values = [ CBC DES
             , CBC DES_EDE3
             , CBC AES128
             , CBC AES192
             , CBC AES256
             , CBC CAST5
             , CBC Camellia128

             , ECB DES
             , ECB AES128
             , ECB AES192
             , ECB AES256
             , ECB Camellia128

             , CFB DES
             , CFB AES128
             , CFB AES192
             , CFB AES256
             , CFB Camellia128

             , CTR Camellia128
             ]

instance OIDable ContentEncryptionAlg where
    getObjectID (CBC DES)          = [1,3,14,3,2,7]
    getObjectID (CBC DES_EDE3)     = [1,2,840,113549,3,7]
    getObjectID (CBC AES128)       = [2,16,840,1,101,3,4,1,2]
    getObjectID (CBC AES192)       = [2,16,840,1,101,3,4,1,22]
    getObjectID (CBC AES256)       = [2,16,840,1,101,3,4,1,42]
    getObjectID (CBC CAST5)        = [1,2,840,113533,7,66,10]
    getObjectID (CBC Camellia128)  = [1,2,392,200011,61,1,1,1,2]

    getObjectID (ECB DES)          = [1,3,14,3,2,6]
    getObjectID (ECB AES128)       = [2,16,840,1,101,3,4,1,1]
    getObjectID (ECB AES192)       = [2,16,840,1,101,3,4,1,21]
    getObjectID (ECB AES256)       = [2,16,840,1,101,3,4,1,41]
    getObjectID (ECB Camellia128)  = [0,3,4401,5,3,1,9,1]

    getObjectID (CFB DES)          = [1,3,14,3,2,9]
    getObjectID (CFB AES128)       = [2,16,840,1,101,3,4,1,4]
    getObjectID (CFB AES192)       = [2,16,840,1,101,3,4,1,24]
    getObjectID (CFB AES256)       = [2,16,840,1,101,3,4,1,44]
    getObjectID (CFB Camellia128)  = [0,3,4401,5,3,1,9,4]

    getObjectID (CTR Camellia128)  = [0,3,4401,5,3,1,9,9]

    getObjectID ty = error ("Unsupported ContentEncryptionAlg: " ++ show ty)

instance OIDNameable ContentEncryptionAlg where
    fromObjectID oid = unOIDNW <$> fromObjectID oid

-- | Content encryption algorithm with associated parameters (i.e. the
-- initialization vector).
--
-- A value can be generated with 'generateEncryptionParams'.
data ContentEncryptionParams
    = forall c . BlockCipher c => ParamsECB (ContentEncryptionCipher c)
      -- ^ Electronic Codebook
    | forall c . BlockCipher c => ParamsCBC (ContentEncryptionCipher c) (IV c)
      -- ^ Cipher Block Chaining
    | forall c . BlockCipher c => ParamsCFB (ContentEncryptionCipher c) (IV c)
      -- ^ Cipher Feedback
    | forall c . BlockCipher c => ParamsCTR (ContentEncryptionCipher c) (IV c)
      -- ^ Counter

instance Show ContentEncryptionParams where
    show = show . getContentEncryptionAlg

instance Eq ContentEncryptionParams where
    ParamsECB c1     == ParamsECB c2     = cecI c1 == cecI c2
    ParamsCBC c1 iv1 == ParamsCBC c2 iv2 = cecI c1 == cecI c2 && iv1 `eqBA` iv2
    ParamsCFB c1 iv1 == ParamsCFB c2 iv2 = cecI c1 == cecI c2 && iv1 `eqBA` iv2
    ParamsCTR c1 iv1 == ParamsCTR c2 iv2 = cecI c1 == cecI c2 && iv1 `eqBA` iv2
    _               == _               = False

instance HasKeySize ContentEncryptionParams where
    getKeySizeSpecifier (ParamsECB c)   = getCipherKeySizeSpecifier c
    getKeySizeSpecifier (ParamsCBC c _) = getCipherKeySizeSpecifier c
    getKeySizeSpecifier (ParamsCFB c _) = getCipherKeySizeSpecifier c
    getKeySizeSpecifier (ParamsCTR c _) = getCipherKeySizeSpecifier c

instance ASN1Elem e => ProduceASN1Object e ContentEncryptionParams where
    asn1s param =
        asn1Container Sequence (oid . params)
      where
        oid    = gOID (getObjectID $ getContentEncryptionAlg param)
        params = ceParameterASN1S param

instance Monoid e => ParseASN1Object e ContentEncryptionParams where
    parse = onNextContainer Sequence $ do
        OID oid <- getNext
        withObjectID "content encryption algorithm" oid parseCEParameter

ceParameterASN1S :: ASN1Elem e => ContentEncryptionParams -> ASN1Stream e
ceParameterASN1S (ParamsECB _)    = id
ceParameterASN1S (ParamsCBC _ iv) = gOctetString (B.convert iv)
ceParameterASN1S (ParamsCFB _ iv) = gOctetString (B.convert iv)
ceParameterASN1S (ParamsCTR _ iv) = gOctetString (B.convert iv)

parseCEParameter :: Monoid e
                 => ContentEncryptionAlg -> ParseASN1 e ContentEncryptionParams
parseCEParameter (ECB c) = getMany getNext >> return (ParamsECB c)
parseCEParameter (CBC c) = ParamsCBC c <$> (getNext >>= getIV)
parseCEParameter (CFB c) = ParamsCFB c <$> (getNext >>= getIV)
parseCEParameter (CTR c) = ParamsCTR c <$> (getNext >>= getIV)

getIV :: BlockCipher cipher => ASN1 -> ParseASN1 e (IV cipher)
getIV (OctetString ivBs) =
    case makeIV ivBs of
        Nothing -> throwParseError "Bad IV in parsed parameters"
        Just v  -> return v
getIV _ = throwParseError "No IV in parsed parameter or incorrect format"

-- | Get the content encryption algorithm.
getContentEncryptionAlg :: ContentEncryptionParams -> ContentEncryptionAlg
getContentEncryptionAlg (ParamsECB c)   = ECB c
getContentEncryptionAlg (ParamsCBC c _) = CBC c
getContentEncryptionAlg (ParamsCFB c _) = CFB c
getContentEncryptionAlg (ParamsCTR c _) = CTR c

-- | Generate random parameters for the specified content encryption algorithm.
generateEncryptionParams :: MonadRandom m
                         => ContentEncryptionAlg -> m ContentEncryptionParams
generateEncryptionParams (ECB c) = return (ParamsECB c)
generateEncryptionParams (CBC c) = ParamsCBC c <$> ivGenerate undefined
generateEncryptionParams (CFB c) = ParamsCFB c <$> ivGenerate undefined
generateEncryptionParams (CTR c) = ParamsCTR c <$> ivGenerate undefined

-- | Encrypt a bytearray with the specified content encryption key and
-- algorithm.
contentEncrypt :: (ByteArray cek, ByteArray ba)
               => cek
               -> ContentEncryptionParams
               -> ba -> Either String ba
contentEncrypt key params bs =
    case params of
        ParamsECB cipher    -> getCipher cipher key >>= (\c -> force $ ecbEncrypt c    $ padded c bs)
        ParamsCBC cipher iv -> getCipher cipher key >>= (\c -> force $ cbcEncrypt c iv $ padded c bs)
        ParamsCFB cipher iv -> getCipher cipher key >>= (\c -> force $ cfbEncrypt c iv $ padded c bs)
        ParamsCTR cipher iv -> getCipher cipher key >>= (\c -> force $ ctrCombine c iv $ padded c bs)
  where
    force x  = x `seq` Right x
    padded c = pad (PKCS7 $ blockSize c)

-- | Decrypt a bytearray with the specified content encryption key and
-- algorithm.
contentDecrypt :: (ByteArray cek, ByteArray ba)
               => cek
               -> ContentEncryptionParams
               -> ba -> Either String ba
contentDecrypt key params bs =
    case params of
        ParamsECB cipher    -> getCipher cipher key >>= (\c -> unpadded c (ecbDecrypt c    bs))
        ParamsCBC cipher iv -> getCipher cipher key >>= (\c -> unpadded c (cbcDecrypt c iv bs))
        ParamsCFB cipher iv -> getCipher cipher key >>= (\c -> unpadded c (cfbDecrypt c iv bs))
        ParamsCTR cipher iv -> getCipher cipher key >>= (\c -> unpadded c (ctrCombine c iv bs))
  where
    unpadded c decrypted =
        case unpad (PKCS7 $ blockSize c) decrypted of
            Nothing  -> Left "Decryption failed, incorrect key or password?"
            Just out -> Right out


-- PRF

-- | Pseudorandom function used for PBKDF2.
data PBKDF2_PRF = PBKDF2_SHA1   -- ^ hmacWithSHA1
                | PBKDF2_SHA256 -- ^ hmacWithSHA256
                | PBKDF2_SHA512 -- ^ hmacWithSHA512
                deriving (Show,Eq)

instance Enumerable PBKDF2_PRF where
    values = [ PBKDF2_SHA1
             , PBKDF2_SHA256
             , PBKDF2_SHA512
             ]

instance OIDable PBKDF2_PRF where
    getObjectID PBKDF2_SHA1   = [1,2,840,113549,2,7]
    getObjectID PBKDF2_SHA256 = [1,2,840,113549,2,9]
    getObjectID PBKDF2_SHA512 = [1,2,840,113549,2,11]

instance OIDNameable PBKDF2_PRF where
    fromObjectID oid = unOIDNW <$> fromObjectID oid

instance AlgorithmId PBKDF2_PRF where
    type AlgorithmType PBKDF2_PRF = PBKDF2_PRF
    algorithmName _  = "PBKDF2 PRF"
    algorithmType    = id
    parameterASN1S _ = id
    parseParameter p = getNextMaybe nullOrNothing >> return p

-- | Invoke the pseudorandom function.
prf :: (ByteArrayAccess salt, ByteArrayAccess password, ByteArray out)
    => PBKDF2_PRF -> PBKDF2.Parameters -> password -> salt -> out
prf PBKDF2_SHA1   = PBKDF2.fastPBKDF2_SHA1
prf PBKDF2_SHA256 = PBKDF2.fastPBKDF2_SHA256
prf PBKDF2_SHA512 = PBKDF2.fastPBKDF2_SHA512


-- Key derivation

-- | Salt value used for key derivation.
type Salt = ByteString

-- | Key derivation algorithm.
data KeyDerivationAlgorithm = TypePBKDF2 | TypeScrypt

instance Enumerable KeyDerivationAlgorithm where
    values = [ TypePBKDF2
             , TypeScrypt
             ]

instance OIDable KeyDerivationAlgorithm where
    getObjectID TypePBKDF2 = [1,2,840,113549,1,5,12]
    getObjectID TypeScrypt = [1,3,6,1,4,1,11591,4,11]

instance OIDNameable KeyDerivationAlgorithm where
    fromObjectID oid = unOIDNW <$> fromObjectID oid

-- | Key derivation algorithm and associated parameters.
data KeyDerivationFunc =
      -- | Key derivation with PBKDF2
      PBKDF2 { pbkdf2Salt           :: Salt       -- ^ Salt value
             , pbkdf2IterationCount :: Int        -- ^ Iteration count
             , pbkdf2KeyLength      :: Maybe Int  -- ^ Optional key length
             , pbkdf2Prf            :: PBKDF2_PRF -- ^ Pseudorandom function
             }
      -- | Key derivation with Scrypt
    | Scrypt { scryptSalt      :: Salt       -- ^ Salt value
             , scryptN         :: Word64     -- ^ N value
             , scryptR         :: Int        -- ^ R value
             , scryptP         :: Int        -- ^ P value
             , scryptKeyLength :: Maybe Int  -- ^ Optional key length
             }
    deriving (Show,Eq)

instance AlgorithmId KeyDerivationFunc where
    type AlgorithmType KeyDerivationFunc = KeyDerivationAlgorithm

    algorithmName _ = "key derivation algorithm"
    algorithmType PBKDF2{..} = TypePBKDF2
    algorithmType Scrypt{..} = TypeScrypt

    parameterASN1S PBKDF2{..} =
        asn1Container Sequence (salt . iters . keyLen . mprf)
      where
        salt   = gOctetString pbkdf2Salt
        iters  = gIntVal (toInteger pbkdf2IterationCount)
        keyLen = maybe id (gIntVal . toInteger) pbkdf2KeyLength
        mprf   = if pbkdf2Prf == PBKDF2_SHA1 then id else algorithmASN1S Sequence pbkdf2Prf

    parameterASN1S Scrypt{..} =
        asn1Container Sequence (salt . n . r . p . keyLen)
      where
        salt   = gOctetString scryptSalt
        n      = gIntVal (toInteger scryptN)
        r      = gIntVal (toInteger scryptR)
        p      = gIntVal (toInteger scryptP)
        keyLen = maybe id (gIntVal . toInteger) scryptKeyLength

    parseParameter TypePBKDF2 = onNextContainer Sequence $ do
        OctetString salt <- getNext
        IntVal iters <- getNext
        keyLen <- getNextMaybe intOrNothing
        b <- hasNext
        mprf <- if b then parseAlgorithm Sequence else return PBKDF2_SHA1
        return PBKDF2 { pbkdf2Salt           = salt
                      , pbkdf2IterationCount = fromInteger iters
                      , pbkdf2KeyLength      = fromInteger <$> keyLen
                      , pbkdf2Prf            = mprf
                      }

    parseParameter TypeScrypt = onNextContainer Sequence $ do
        OctetString salt <- getNext
        IntVal n <- getNext
        IntVal r <- getNext
        IntVal p <- getNext
        keyLen <- getNextMaybe intOrNothing
        return Scrypt { scryptSalt      = salt
                      , scryptN         = fromInteger n
                      , scryptR         = fromInteger r
                      , scryptP         = fromInteger p
                      , scryptKeyLength = fromInteger <$> keyLen
                      }

-- | Return the optional key length stored in the KDF parameters.
kdfKeyLength :: KeyDerivationFunc -> Maybe Int
kdfKeyLength PBKDF2{..} = pbkdf2KeyLength
kdfKeyLength Scrypt{..} = scryptKeyLength

-- | Run a key derivation function to produce a result of the specified length
-- using the supplied password.
kdfDerive :: (ByteArrayAccess password, ByteArray out)
          => KeyDerivationFunc -> Int -> password -> out
kdfDerive PBKDF2{..} len pwd = prf pbkdf2Prf params pwd pbkdf2Salt
  where params = PBKDF2.Parameters pbkdf2IterationCount len
kdfDerive Scrypt{..} len pwd = Scrypt.generate params pwd scryptSalt
  where params = Scrypt.Parameters { Scrypt.n = scryptN
                                   , Scrypt.r = scryptR
                                   , Scrypt.p = scryptP
                                   , Scrypt.outputLength = len
                                   }

-- | Generate a random salt with the specified length in bytes.  To be most
-- effective, the length should be at least 8 bytes.
generateSalt :: MonadRandom m => Int -> m Salt
generateSalt = getRandomBytes


-- Key encryption

data KeyEncryptionType = TypePWRIKEK
                       | TypeAES128_WRAP
                       | TypeAES192_WRAP
                       | TypeAES256_WRAP
                       | TypeAES128_WRAP_PAD
                       | TypeAES192_WRAP_PAD
                       | TypeAES256_WRAP_PAD
                       | TypeDES_EDE3_WRAP

instance Enumerable KeyEncryptionType where
    values = [ TypePWRIKEK
             , TypeAES128_WRAP
             , TypeAES192_WRAP
             , TypeAES256_WRAP
             , TypeAES128_WRAP_PAD
             , TypeAES192_WRAP_PAD
             , TypeAES256_WRAP_PAD
             , TypeDES_EDE3_WRAP
             ]

instance OIDable KeyEncryptionType where
    getObjectID TypePWRIKEK         = [1,2,840,113549,1,9,16,3,9]

    getObjectID TypeAES128_WRAP     = [2,16,840,1,101,3,4,1,5]
    getObjectID TypeAES192_WRAP     = [2,16,840,1,101,3,4,1,25]
    getObjectID TypeAES256_WRAP     = [2,16,840,1,101,3,4,1,45]

    getObjectID TypeAES128_WRAP_PAD = [2,16,840,1,101,3,4,1,8]
    getObjectID TypeAES192_WRAP_PAD = [2,16,840,1,101,3,4,1,28]
    getObjectID TypeAES256_WRAP_PAD = [2,16,840,1,101,3,4,1,48]

    getObjectID TypeDES_EDE3_WRAP   = [1,2,840,113549,1,9,16,3,6]

instance OIDNameable KeyEncryptionType where
    fromObjectID oid = unOIDNW <$> fromObjectID oid

-- | Key encryption algorithm with associated parameters (i.e. the underlying
-- encryption algorithm).
data KeyEncryptionParams = PWRIKEK ContentEncryptionParams  -- ^ PWRI-KEK key wrap algorithm
                         | AES128_WRAP                      -- ^ AES-128 key wrap
                         | AES192_WRAP                      -- ^ AES-192 key wrap
                         | AES256_WRAP                      -- ^ AES-256 key wrap
                         | AES128_WRAP_PAD                  -- ^ AES-128 extended key wrap
                         | AES192_WRAP_PAD                  -- ^ AES-192 extended key wrap
                         | AES256_WRAP_PAD                  -- ^ AES-256 extended key wrap
                         | DES_EDE3_WRAP                    -- ^ Triple-DES key wrap
                         deriving (Show,Eq)

instance AlgorithmId KeyEncryptionParams where
    type AlgorithmType KeyEncryptionParams = KeyEncryptionType
    algorithmName _ = "key encryption algorithm"

    algorithmType (PWRIKEK _)      = TypePWRIKEK
    algorithmType AES128_WRAP      = TypeAES128_WRAP
    algorithmType AES192_WRAP      = TypeAES192_WRAP
    algorithmType AES256_WRAP      = TypeAES256_WRAP
    algorithmType AES128_WRAP_PAD  = TypeAES128_WRAP_PAD
    algorithmType AES192_WRAP_PAD  = TypeAES192_WRAP_PAD
    algorithmType AES256_WRAP_PAD  = TypeAES256_WRAP_PAD
    algorithmType DES_EDE3_WRAP    = TypeDES_EDE3_WRAP

    parameterASN1S (PWRIKEK cep)  = asn1s cep
    parameterASN1S _              = id

    parseParameter TypePWRIKEK          = PWRIKEK <$> parse
    parseParameter TypeAES128_WRAP      = return AES128_WRAP
    parseParameter TypeAES192_WRAP      = return AES192_WRAP
    parseParameter TypeAES256_WRAP      = return AES256_WRAP
    parseParameter TypeAES128_WRAP_PAD  = return AES128_WRAP_PAD
    parseParameter TypeAES192_WRAP_PAD  = return AES192_WRAP_PAD
    parseParameter TypeAES256_WRAP_PAD  = return AES256_WRAP_PAD
    parseParameter TypeDES_EDE3_WRAP    = return DES_EDE3_WRAP

instance HasKeySize KeyEncryptionParams where
    getKeySizeSpecifier (PWRIKEK cep)   = getKeySizeSpecifier cep
    getKeySizeSpecifier AES128_WRAP     = getCipherKeySizeSpecifier AES128
    getKeySizeSpecifier AES192_WRAP     = getCipherKeySizeSpecifier AES192
    getKeySizeSpecifier AES256_WRAP     = getCipherKeySizeSpecifier AES256
    getKeySizeSpecifier AES128_WRAP_PAD = getCipherKeySizeSpecifier AES128
    getKeySizeSpecifier AES192_WRAP_PAD = getCipherKeySizeSpecifier AES192
    getKeySizeSpecifier AES256_WRAP_PAD = getCipherKeySizeSpecifier AES256
    getKeySizeSpecifier DES_EDE3_WRAP   = getCipherKeySizeSpecifier DES_EDE3

-- | Encrypt a key with the specified key encryption key and algorithm.
keyEncrypt :: (MonadRandom m, ByteArray kek, ByteArray ba)
           => kek -> KeyEncryptionParams -> ba -> m (Either String ba)
keyEncrypt key (PWRIKEK params) bs =
    case params of
        ParamsECB cipher    -> let cc = getCipher cipher key in either (return . Left) (\c -> wrapEncrypt (const . ecbEncrypt) c undefined bs) cc
        ParamsCBC cipher iv -> let cc = getCipher cipher key in either (return . Left) (\c -> wrapEncrypt cbcEncrypt c iv bs) cc
        ParamsCFB cipher iv -> let cc = getCipher cipher key in either (return . Left) (\c -> wrapEncrypt cfbEncrypt c iv bs) cc
        ParamsCTR _ _       -> return (Left "Unable to wrap key in CTR mode")
keyEncrypt key AES128_WRAP      bs = return (getCipher AES128 key >>= (`AES_KW.wrap` bs))
keyEncrypt key AES192_WRAP      bs = return (getCipher AES192 key >>= (`AES_KW.wrap` bs))
keyEncrypt key AES256_WRAP      bs = return (getCipher AES256 key >>= (`AES_KW.wrap` bs))
keyEncrypt key AES128_WRAP_PAD  bs = return (getCipher AES128 key >>= (`AES_KW.wrapPad` bs))
keyEncrypt key AES192_WRAP_PAD  bs = return (getCipher AES192 key >>= (`AES_KW.wrapPad` bs))
keyEncrypt key AES256_WRAP_PAD  bs = return (getCipher AES256 key >>= (`AES_KW.wrapPad` bs))
keyEncrypt key DES_EDE3_WRAP    bs = either (return . Left) (wrap3DES bs) (getCipher DES_EDE3 key)
  where wrap3DES b c = (\iv -> TripleDES_KW.wrap c iv b) <$> ivGenerate c

-- | Decrypt a key with the specified key encryption key and algorithm.
keyDecrypt :: (ByteArray kek, ByteArray ba)
           => kek -> KeyEncryptionParams -> ba -> Either String ba
keyDecrypt key (PWRIKEK params) bs =
    case params of
        ParamsECB cipher    -> getCipher cipher key >>= (\c -> wrapDecrypt (const . ecbDecrypt) c undefined bs)
        ParamsCBC cipher iv -> getCipher cipher key >>= (\c -> wrapDecrypt cbcDecrypt c iv bs)
        ParamsCFB cipher iv -> getCipher cipher key >>= (\c -> wrapDecrypt cfbDecrypt c iv bs)
        ParamsCTR _ _       -> Left "Unable to unwrap key in CTR mode"
keyDecrypt key AES128_WRAP      bs = getCipher AES128   key >>= (`AES_KW.unwrap` bs)
keyDecrypt key AES192_WRAP      bs = getCipher AES192   key >>= (`AES_KW.unwrap` bs)
keyDecrypt key AES256_WRAP      bs = getCipher AES256   key >>= (`AES_KW.unwrap` bs)
keyDecrypt key AES128_WRAP_PAD  bs = getCipher AES128   key >>= (`AES_KW.unwrapPad` bs)
keyDecrypt key AES192_WRAP_PAD  bs = getCipher AES192   key >>= (`AES_KW.unwrapPad` bs)
keyDecrypt key AES256_WRAP_PAD  bs = getCipher AES256   key >>= (`AES_KW.unwrapPad` bs)
keyDecrypt key DES_EDE3_WRAP    bs = getCipher DES_EDE3 key >>= (`TripleDES_KW.unwrap` bs)

keyWrap :: (MonadRandom m, ByteArray ba)
        => Int -> ba -> m (Either String ba)
keyWrap sz input
    | inLen <   3 = return $ Left "keyWrap: input key too short"
    | inLen > 255 = return $ Left "keyWrap: input key too long"
    | pLen == 0   = return $ Right $ B.concat [ count, check, input ]
    | otherwise   = do
        padding <- getRandomBytes pLen
        return $ Right $ B.concat [ count, check, input, padding ]
  where
    inLen = B.length input
    count = B.singleton (fromIntegral inLen)
    check = B.xor input (B.pack [255, 255, 255] :: B.Bytes)
    pLen  = sz - (inLen + 4) `mod` sz + comp
    comp  = if inLen + 4 > sz then 0 else sz

keyUnwrap :: ByteArray ba => ba -> Either String ba
keyUnwrap input
    | inLen < 4         = Left "keyUnwrap: invalid wrapped key"
    | check /= 255      = Left "keyUnwrap: invalid wrapped key"
    | inLen < count - 4 = Left "keyUnwrap: invalid wrapped key"
    | otherwise         = Right $ B.take count (B.drop 4 input)
  where
    inLen = B.length input
    count = fromIntegral (B.index input 0)
    bytes = [ B.index input (i + 1) `xor` B.index input (i + 4) | i <- [0..2] ]
    check = foldl1 (.&.) bytes

wrapEncrypt :: (MonadRandom m, BlockCipher cipher, ByteArray ba)
            => (cipher -> IV cipher -> ba -> ba)
            -> cipher -> IV cipher -> ba -> m (Either String ba)
wrapEncrypt encFn cipher iv input = do
    wrapped <- keyWrap sz input
    return (fn <$> wrapped)
  where
    sz = blockSize cipher
    fn formatted =
        let firstPass = encFn cipher iv formatted
            lastBlock = B.drop (B.length firstPass - sz) firstPass
            Just iv'  = makeIV lastBlock
         in encFn cipher iv' firstPass

wrapDecrypt :: (BlockCipher cipher, ByteArray ba)
            => (cipher -> IV cipher -> ba -> ba)
            -> cipher -> IV cipher -> ba -> Either String ba
wrapDecrypt decFn cipher iv input = keyUnwrap (decFn cipher iv firstPass)
  where
    sz = blockSize cipher
    (beg, lb) = B.splitAt (B.length input - sz) input
    lastBlock = decFn cipher iv' lb
    Just iv'  = makeIV (B.drop (B.length beg - sz) beg)
    Just iv'' = makeIV lastBlock
    firstPass = decFn cipher iv'' beg `B.append` lastBlock


-- Utilities

getCipher :: (BlockCipher cipher, ByteArray key)
          => proxy cipher -> key -> Either String cipher
getCipher _ key =
    case cipherInit key of
        CryptoPassed c -> Right c
        CryptoFailed e -> Left ("Unable to use key: " ++ show e)

ivGenerate :: (BlockCipher cipher, MonadRandom m) => cipher -> m (IV cipher)
ivGenerate cipher = do
    bs <- getRandomBytes (blockSize cipher)
    let Just iv = makeIV (bs :: ByteString)
    return iv

cipherFromProxy :: proxy cipher -> cipher
cipherFromProxy _ = undefined

-- | Return the block size of the specified block cipher.
proxyBlockSize :: BlockCipher cipher => proxy cipher -> Int
proxyBlockSize = blockSize . cipherFromProxy
