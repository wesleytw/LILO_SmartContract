// SPDX-License-Identifier: MIT

// LILOS is a P2P NFT Rental Contract. User can rent 
// NFT using tokens or another NFT as collateral. LILO 
// transactions are acceptable in LILOS.

// Lilos_V1 contract only realized P2P lease using $ETH
// as collateral. Stable coins collateralized lease 
// agreement and NFT collateralized lease agreement 
// will be implemented in Lilos_StableCoin_V1 contract 
// and Lilos_NFT_V1 contract so as to save gas. LILO 
// transactions will be realized in Lilos_V2 contract.

// Lease in/ lease out (“LILO”) mechanism is not realized in this version yet.
// Each item can only be leased once in the leasing term. 
// The repayer is not limited to be the original lessee. 
// Thus, please do not lease for shorting or your collateral may be withdrawn. 
// Ultimate LILO structure: https://drive.google.com/file/d/1K5gECGqXFBeFQl89Y8XbJqIvNvmPQv7-/view?usp=sharing
// Learn more about LILOs: https://assets.kpmg/content/dam/kpmg/au/pdf/2017/foreign-resident-vessels-cross-border-leasing-april-2017.pdf
// LILO transactions: https://papers.ssrn.com/sol3/papers.cfm?abstract_id=975112
// http://www.woodllp.com/Publications/Articles/pdf/SILOs_and_LILOs_Demystified.pdf
	

pragma solidity ^0.8.9;

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

contract Lilos_V1 {
	using SafeMath for uint256;
	address public owner;
	// Platform charges 5% of the rental. 
	uint256 private platformFeeRate = 95; 
    constructor() {
	    owner = msg.sender;
    }
	
	enum ListingStatus {
		Active,
		Leased,
        Delisted
	}

	struct ListingItem {
		ListingStatus status;
		address lessor;
		address lessee;
		address collection;
		uint256 tokenId;
		uint256 collateral_value;   // in wei
        uint256 rental_value;       // in wei
        uint256 lease_term;         // in seconds(timestamp)
		uint256 lease_start_date;
		uint256 lease_end_date;
	}

	/* Events */
	event Listed(
		uint256 indexed listingId,
		ListingStatus status,
		address indexed lessor,
		address collection,
		uint256 tokenId,
		uint256 collateral_value,
        uint256 rental_value,
        uint256 lease_term
	);

	event Delisted(
		uint256 listingId,
		address lessor
	);

	event Leased(
		uint256 indexed listingId,
		address indexed lessor,
		address indexed lessee,
		address collection,
		uint256 tokenId,
		uint256 collateral_value,
        uint256 rental_value,
        uint256 lease_term,
		uint256 lease_start_date,
		uint256 lease_end_date
	);

    event Repayed(
		uint256 indexed listingId,
		address lessor,
		address indexed lessee,
		address indexed repayer,
		address collection,
		uint256 tokenId,
		uint256 collateral_value,
        uint256 lease_term,
        uint256 lease_start_date,
		uint256 lease_end_date
	);

    event Liquidated(
		uint256 indexed listingId,
		address indexed lessor,
		address indexed lessee,
		address collection,
		uint256 tokenId,
		uint256 collateral_value,
        uint256 lease_term,
		uint256 lease_start_date,
		uint256 lease_end_date,
		uint256 Liquidated_date
	);

	/* Main functions */
	uint256 private _listingId;
	uint256 private _max_listingId = 10000;
	// If we use collection and tokenId as index, we cannot query all tokens not knowing the collection and tokenId.
	// Thus we set _listingId as index for ListingItem structure and make another mapping for checking out the statue while listing.
	mapping (address => mapping (uint256 => bool)) public isTokenListed;   
	mapping (uint256 => ListingItem) private _listingItems;
	uint256 private _max_lease_term = 10 days;        // 10 days = 864000 seconds(timestamp)
	uint256 private _min_lease_term = 1 minutes;      // 1 mins = 60 seconds(timestamp)
	uint256 private _lease_date_zero = 0;

	function listToken(
		address collection_, 
		uint256 tokenId_, 
		uint256 collateral_value_, 
		uint256 rental_value_,
		uint256 lease_term_
		) external {
		require(_listingId <= _max_listingId, "The listing number reached the limit.");
		require(isTokenListed[collection_][tokenId_] == false, "This token is already listed.");
		require(IERC721(collection_).isApprovedForAll(msg.sender, address(this)), "Lessor should approve Lilos contract to access all tokens of the collection.");
		require(IERC721(collection_).ownerOf(tokenId_) == msg.sender, "Lessor must be the token owner.");
		require(collateral_value_ > 0, "Collateral value should be larger than zero.");
		require(rental_value_ > 0, "Rent value should be larger than zero.");
		require(lease_term_ > _min_lease_term, "Lease term should be longer than 1 minutes.");
		require(lease_term_ < _max_lease_term, "Lease term should be shorter than 10 days.");

		ListingItem memory listingItem = ListingItem(
			ListingStatus.Active,
			msg.sender,
			address(0),     // default lessee is 0x00000... 
			collection_,
			tokenId_,
			collateral_value_,
			rental_value_,
			lease_term_,
			_lease_date_zero,
			_lease_date_zero
		);

		isTokenListed[listingItem.collection][listingItem.tokenId] = true;
		_listingItems[_listingId] = listingItem;

		emit Listed(
			_listingId,
			listingItem.status,
			msg.sender,
			listingItem.collection,
			listingItem.tokenId,
			listingItem.collateral_value,
			listingItem.rental_value,
			listingItem.lease_term
		);
		
		_listingId = _listingId.add(1);

	}

	function delist(uint256 listingId_) public {
		ListingItem storage listingItem = _listingItems[listingId_];

		require(msg.sender == listingItem.lessor, "Only lessor can cancel listing.");
		require(listingItem.status == ListingStatus.Active, "Listing is not active.");

		isTokenListed[listingItem.collection][listingItem.tokenId] = false;
		listingItem.status = ListingStatus.Delisted;
	
		emit Delisted(listingId_, msg.sender);
	}

	function leaseIn(uint256 listingId_) external payable {
		ListingItem storage listingItem = _listingItems[listingId_];

		require(msg.sender != listingItem.lessor, "Lessor cannot be lessee.");
		require(listingItem.status == ListingStatus.Active, "Listing is not active.");

		// This is a precaution to protect lessor.
		// Once the lessor removed the approval to the contract, the lease of the item would be disabled.
		bool isLessorApprovalActive = IERC721(listingItem.collection).isApprovedForAll(listingItem.lessor, address(this));
		if (!isLessorApprovalActive){
			listingItem.status = ListingStatus.Delisted;
		}
		require(isLessorApprovalActive, "Lessor removed the approval of the token to the contract.");
		require(msg.value == (listingItem.collateral_value.add(listingItem.rental_value)), "msg.value dose not match the total spending.");

		IERC721(listingItem.collection).transferFrom(listingItem.lessor, msg.sender, listingItem.tokenId);
		//(bool success,)
		payable(listingItem.lessor).transfer(listingItem.rental_value.mul(platformFeeRate).div(100));
		listingItem.status = ListingStatus.Leased;
		listingItem.lessee = msg.sender;
		listingItem.lease_start_date = block.timestamp;
		listingItem.lease_end_date = listingItem.lease_start_date.add(listingItem.lease_term);

		emit Leased(
			listingId_,
			listingItem.lessor,
			listingItem.lessee,
			listingItem.collection,
			listingItem.tokenId,
			listingItem.collateral_value,
			listingItem.rental_value,
			listingItem.lease_term,
			listingItem.lease_start_date,
			listingItem.lease_end_date
		);
	}
	
	// If the lessee dose not repay the lease and the leasor dose not liquidate the lease, repay function remains executable.
	function repay(uint256 listingId_) public {
		ListingItem storage listingItem = _listingItems[listingId_];

		require(listingItem.status == ListingStatus.Leased, "Token is not leased.");
		// Repayer is not limited to be the original lessee. It is a mechanism of LILO operation.
		require(IERC721(listingItem.collection).ownerOf(listingItem.tokenId) == address(this), "Token is not in the contract vault.");

		payable(msg.sender).transfer(listingItem.collateral_value);
		isTokenListed[listingItem.collection][listingItem.tokenId] = false;
		listingItem.status = ListingStatus.Delisted;
		IERC721(listingItem.collection).transferFrom(address(this), listingItem.lessor, listingItem.tokenId);

		emit Repayed(
			listingId_,
			listingItem.lessor,
			listingItem.lessee,
			msg.sender,
			listingItem.collection,
			listingItem.tokenId,
			listingItem.collateral_value,
			listingItem.lease_term,
			listingItem.lease_start_date,
			listingItem.lease_end_date
		);
	}

	function liquidate(uint256 listingId_) public {
		ListingItem storage listingItem = _listingItems[listingId_];
		require(listingItem.status == ListingStatus.Leased, "Token is not leased.");
		require(listingItem.lessor == msg.sender, "Liquidation can only be implemented by lessor.");
		require(block.timestamp > listingItem.lease_end_date, "Lease is not expired.");
		
		payable(listingItem.lessor).transfer(listingItem.collateral_value);
		isTokenListed[listingItem.collection][listingItem.tokenId] = false;
		listingItem.status = ListingStatus.Delisted;

		emit Liquidated(
			listingId_,
			listingItem.lessor,
			listingItem.lessee,
			listingItem.collection,
			listingItem.tokenId,
			listingItem.collateral_value,
			listingItem.lease_term,
			listingItem.lease_start_date,
			listingItem.lease_end_date,
			block.timestamp
		);
	}

	/* The get functions */
	// Turn the mapping into a struct array to return.
	function getAllItems() public view returns (ListingItem[] memory) {
		ListingItem[] memory items = new ListingItem[](_listingId+1);
		for(uint256 i = 0; i <= _listingId; i++) {
            items[i] = _listingItems[i];
        }
		return items;
	}

	function getItemByListingId(uint256 listingId_) public view returns (ListingItem memory) {
		return _listingItems[listingId_];
	}

	function getItemByCollctionAndTokenId(address collection_, uint256 tokenId_) public view returns (ListingItem memory) {
        ListingItem memory items;
        for (uint256 i = 0; i < _listingId+1; i++) {
			if (_listingItems[i].collection == collection_ && _listingItems[i].tokenId == tokenId_) {
          		items = _listingItems[i];
            }
        }
        return items;
    }

    function getActiveItems() public view returns (ListingItem[] memory) {
		uint256 itemCount;
		uint256 currentFilterIndex;
		for (uint256 i = 0; i < _listingId+1; i++) {
			if (_listingItems[i].status == ListingStatus.Active) {
				itemCount++;
			}
      	}
        ListingItem[] memory items = new ListingItem[](itemCount);
        for (uint256 i = 0; i < _listingId+1; i++) {
            if (_listingItems[i].status == ListingStatus.Active) {
          		items[currentFilterIndex] = _listingItems[i];
				currentFilterIndex++;
            }
        }
        return items;
    }

	function getLeasedItems() public view returns (ListingItem[] memory) {
		uint256 itemCount;
		uint256 currentFilterIndex;
		for (uint256 i = 0; i < _listingId+1; i++) {
			if (_listingItems[i].status == ListingStatus.Leased) {
				itemCount++;
			}
      	}
        ListingItem[] memory items = new ListingItem[](itemCount);
        for (uint256 i = 0; i < _listingId+1; i++) {
            if (_listingItems[i].status == ListingStatus.Leased) {
          		items[currentFilterIndex] = _listingItems[i];
				currentFilterIndex++;
            }
        }
        return items;
    }

	function getItemsByLessor(address lessor_) public view returns (ListingItem[] memory) {
		uint256 itemCount;
		uint256 currentFilterIndex;
		for (uint256 i = 0; i < _listingId+1; i++) {
			if (_listingItems[i].lessor == lessor_) {
				itemCount++;
			}
      	}
        ListingItem[] memory items = new ListingItem[](itemCount);
        for (uint256 i = 0; i < _listingId+1; i++) {
            if (_listingItems[i].lessor == lessor_) {
          		items[currentFilterIndex] = _listingItems[i];
				currentFilterIndex++;
            }
        }
        return items;
    }

	function getItemsByLessee(address lessee_) public view returns (ListingItem[] memory) {
		uint256 itemCount;
		uint256 currentFilterIndex;
		for (uint256 i = 0; i < _listingId+1; i++) {
			if (_listingItems[i].lessee == lessee_) {
				itemCount++;
			}
      	}
        ListingItem[] memory items = new ListingItem[](itemCount);
        for (uint256 i = 0; i < _listingId+1; i++) {
            if (_listingItems[i].lessee == lessee_) {
          		items[currentFilterIndex] = _listingItems[i];
				currentFilterIndex++;
            }
        }
        return items;
    }
// 有getItemByCollctionAndTokenId了
	// function getIsTokenListed() public view returns (uint256) {
	// 	return _listingItems[0].rental_value.mul(platformFeeRate.div(100)).add(99);
	// }

//bug
	function getListingTotal() public view returns (uint256) {
		ListingItem[] memory items = new ListingItem[](_listingId+1);
		for(uint256 i = 0; i <= _listingId; i++) {
            items[i] = _listingItems[i];
        }
		return items.length;
	}

	function getIsExpiredByListingId(uint256 listingId_) public view returns (bool) {
		bool isExpired;
		if(_listingItems[listingId_].status == ListingStatus.Leased){
			if(block.timestamp > _listingItems[listingId_].lease_end_date){
				isExpired = true;
			}
		}
		return isExpired;
	}
	
	function getTime() public view returns (uint256) {
		return block.timestamp;
	}
	
}

/* Reference */
// https://mantlefi.com/
// https://github.com/dabit3/polygon-ethereum-nextjs-marketplace/blob/main/contracts/NFTMarketplace.sol
// https://opensea.io/
// https://nftfi.com/
// https://looksrare.org/
// https://moralis.io/

// gh-repo: https://github.com/wesleytw/LILOS_SmartContract
// The Difference Between a Lease and a Rental Agreement: https://www.mysmartmove.com/SmartMove/blog/difference-between-lease-and-rental-agreement.page
